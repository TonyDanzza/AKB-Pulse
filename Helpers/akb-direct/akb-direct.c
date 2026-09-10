// akb-direct — спящий iPhone глазами АКБ (план §16.2).
//
// Спящий телефон на батарее перестаёт публиковать Bonjour-запись
// `_apple-mobdev2._tcp`, поэтому usbmuxd его «не видит» и `ideviceinfo -n`
// не работает. При этом lockdownd на порту 62078 по-прежнему отвечает —
// волнами, когда телефон просыпается для push. Этот помощник ходит к нему
// напрямую по IP, минуя обнаружение: собирает `idevice_private` вручную
// с `CONNECTION_NETWORK`, а запись сопряжения (и TLS) берёт из Apple usbmuxd.
//
// Режимы:
//   akb-direct battery <ip> <udid>   заряд, вывод как у `ideviceinfo -q`
//   akb-direct health <ip|-> <udid>  здоровье батареи из AppleSmartBattery (план §6.1)
//   akb-direct mac <udid>            WiFiMACAddress из записи сопряжения
//   akb-direct addr <udid>           IPv4, если usbmuxd видит телефон по сети
//   akb-direct watch                 поток событий usbmuxd (план §18.1)
//
// Коды возврата: 0 ок, 2 неверные аргументы, 3 рукопожатие не удалось
// (телефон спит/недоступен), 4 GetValue/сервис не удался, 5 не найдено,
// 6 ответ есть, но нужных полей в нём нет (незнакомая прошивка).
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <stdint.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/diagnostics_relay.h>
#include <usbmuxd.h>
#include <plist/plist.h>

// Зеркало приватной struct idevice_private из libimobiledevice 1.4.0 (src/idevice.h).
// Версия пиннится в scripts/bundle-libimobiledevice.sh: при другой версии сборка падает.
struct idevice_private {
    char *udid;
    uint32_t mux_id;
    enum idevice_connection_type conn_type;
    void *conn_data;
    int version;
    int device_class;
};

static void print_node(const char *key, plist_t node) {
    switch (plist_get_node_type(node)) {
        case PLIST_BOOLEAN: {
            uint8_t b = 0;
            plist_get_bool_val(node, &b);
            printf("%s: %s\n", key, b ? "true" : "false");
            break;
        }
        case PLIST_INT: {
            uint64_t u = 0;
            plist_get_uint_val(node, &u);
            printf("%s: %llu\n", key, (unsigned long long)u);
            break;
        }
        case PLIST_STRING: {
            char *s = NULL;
            plist_get_string_val(node, &s);
            printf("%s: %s\n", key, s ? s : "");
            free(s);
            break;
        }
        default:
            printf("%s: <%d>\n", key, plist_get_node_type(node));
    }
}

// --- общее устройство по IP ---------------------------------------------------

// Самодельный idevice_t с CONNECTION_NETWORK: обнаружение через usbmuxd минуется,
// адрес задаётся прямо. Один код на `battery` и `health` (план §6.1).
// В `*rc` кладётся код возврата помощника, если собрать не вышло.
static struct idevice_private *make_direct_device(const char *ip, const char *udid, int *rc) {
    struct sockaddr_in *sa = calloc(1, sizeof(*sa));
    if (!sa) { *rc = 4; return NULL; }
    sa->sin_family = AF_INET;
    sa->sin_len = sizeof(*sa);
    sa->sin_port = 0;
    if (inet_pton(AF_INET, ip, &sa->sin_addr) != 1) {
        fprintf(stderr, "bad ip\n");
        free(sa);
        *rc = 2;
        return NULL;
    }
    struct idevice_private *dev = calloc(1, sizeof(*dev));
    if (!dev) { free(sa); *rc = 4; return NULL; }
    dev->udid = strdup(udid);
    dev->conn_type = CONNECTION_NETWORK;
    dev->conn_data = sa;   // дальше sa принадлежит dev и освобождается один раз
    return dev;
}

static void free_direct_device(struct idevice_private *dev) {
    if (!dev) return;
    free(dev->udid);
    free(dev->conn_data);
    free(dev);
}

// --- battery -----------------------------------------------------------------

static int mode_battery(const char *ip, const char *udid, const char *domain) {
    // Освобождаем всё на любом пути: общий выход `out` (план §11).
    int rc = 0;
    struct idevice_private *dev = make_direct_device(ip, udid, &rc);
    if (!dev) return rc;
    lockdownd_client_t client = NULL;
    plist_t val = NULL;
    plist_dict_iter it = NULL;
    char *key = NULL;
    plist_t node = NULL;

    lockdownd_error_t lerr =
        lockdownd_client_new_with_handshake((idevice_t)dev, &client, "AKB");
    if (lerr != LOCKDOWN_E_SUCCESS) {
        fprintf(stderr, "lockdown handshake failed: %d\n", lerr);
        rc = 3;
        goto out;
    }
    lerr = lockdownd_get_value(client, domain, NULL, &val);
    if (lerr != LOCKDOWN_E_SUCCESS || !val) {
        fprintf(stderr, "get_value failed: %d\n", lerr);
        rc = 4;
        goto out;
    }
    plist_dict_new_iter(val, &it);
    while (1) {
        plist_dict_next_item(val, it, &key, &node);
        if (!key) break;
        print_node(key, node);
        free(key);
        key = NULL;
    }
out:
    free(it);
    if (val) plist_free(val);
    // Клиент держит idevice_t, поэтому уходит первым.
    if (client) lockdownd_client_free(client);
    free_direct_device(dev);
    return rc;
}

// --- health ------------------------------------------------------------------

// Здоровье батареи живёт в записи IORegistry `AppleSmartBattery`, а её отдаёт
// сервис com.apple.mobile.diagnostics_relay по той же доверенной паре, что и заряд.
// Наружу уходит только белый список полей: в ответе есть ещё серийный номер
// батареи и телеметрия, и им в логах приложения делать нечего (план §6.1).
static const char *const health_keys[] = {
    "CycleCount", "Voltage", "InstantAmperage", "Amperage",
    "Temperature", "TimeRemaining", "IsCharging", "ExternalConnected"
};
static const char *const health_battery_data_keys[] = {
    "DesignCapacity", "NominalChargeCapacity", "FullChargeCapacity"
};

// Целые печатаем знаковыми: ток при разряде отрицательный, и plist_get_uint_val
// превратил бы −58 в 18446744073709551558.
static void print_health_node(const char *key, plist_t node) {
    if (!node) return;
    switch (plist_get_node_type(node)) {
        case PLIST_BOOLEAN: {
            uint8_t b = 0;
            plist_get_bool_val(node, &b);
            printf("%s: %s\n", key, b ? "true" : "false");
            break;
        }
        case PLIST_INT: {
            int64_t i = 0;
            plist_get_int_val(node, &i);
            printf("%s: %lld\n", key, (long long)i);
            break;
        }
        case PLIST_REAL: {
            double d = 0;
            plist_get_real_val(node, &d);
            printf("%s: %g\n", key, d);
            break;
        }
        default:
            break;   // строк и словарей в белом списке нет
    }
}

static void print_health_group(plist_t dict, const char *const *keys, size_t count) {
    if (!dict || plist_get_node_type(dict) != PLIST_DICT) return;
    for (size_t i = 0; i < count; i++)
        print_health_node(keys[i], plist_dict_get_item(dict, keys[i]));
}

// `ip` == "-" — путь через usbmuxd: так здоровье читается у бодрствующего телефона,
// которого видно обычным обнаружением. Иначе — прямой путь по IP.
static int mode_health(const char *ip, const char *udid) {
    int rc = 0;
    int direct = strcmp(ip, "-") != 0;
    struct idevice_private *own = NULL;
    idevice_t dev = NULL;

    if (direct) {
        own = make_direct_device(ip, udid, &rc);
        if (!own) return rc;
        dev = (idevice_t)own;
    } else if (idevice_new_with_options(&dev, udid,
                                        IDEVICE_LOOKUP_USBMUX | IDEVICE_LOOKUP_NETWORK)
               != IDEVICE_E_SUCCESS || !dev) {
        fprintf(stderr, "device not found\n");
        return 3;
    }

    lockdownd_client_t client = NULL;
    lockdownd_service_descriptor_t service = NULL;
    diagnostics_relay_client_t diag = NULL;
    plist_t result = NULL;
    plist_t registry = NULL;

    lockdownd_error_t lerr = lockdownd_client_new_with_handshake(dev, &client, "AKB");
    if (lerr != LOCKDOWN_E_SUCCESS) {
        fprintf(stderr, "lockdown handshake failed: %d\n", lerr);
        rc = 3;
        goto out;
    }
    lerr = lockdownd_start_service(client, DIAGNOSTICS_RELAY_SERVICE_NAME, &service);
    if (lerr != LOCKDOWN_E_SUCCESS || !service) {
        fprintf(stderr, "start_service failed: %d\n", lerr);
        rc = 4;
        goto out;
    }
    if (diagnostics_relay_client_new(dev, service, &diag) != DIAGNOSTICS_RELAY_E_SUCCESS) {
        fprintf(stderr, "diagnostics_relay client failed\n");
        rc = 4;
        goto out;
    }
    if (diagnostics_relay_query_ioregistry_entry(diag, "AppleSmartBattery", NULL, &result)
            != DIAGNOSTICS_RELAY_E_SUCCESS || !result) {
        fprintf(stderr, "ioregistry query failed\n");
        rc = 4;
        goto out;
    }

    registry = plist_dict_get_item(result, "IORegistry");
    if (!registry || plist_get_node_type(registry) != PLIST_DICT
        || !plist_dict_get_item(registry, "CycleCount")) {
        fprintf(stderr, "AppleSmartBattery: unexpected answer\n");
        rc = 6;
        goto out;
    }

    print_health_group(registry, health_keys,
                       sizeof(health_keys) / sizeof(health_keys[0]));
    print_health_group(plist_dict_get_item(registry, "BatteryData"),
                       health_battery_data_keys,
                       sizeof(health_battery_data_keys) / sizeof(health_battery_data_keys[0]));

out:
    if (result) plist_free(result);
    if (diag) {
        diagnostics_relay_goodbye(diag);
        diagnostics_relay_client_free(diag);
    }
    if (service) lockdownd_service_descriptor_free(service);
    if (client) lockdownd_client_free(client);
    if (own) free_direct_device(own);
    else if (dev) idevice_free(dev);
    return rc;
}

// --- mac ---------------------------------------------------------------------

// `arp -an` печатает MAC без ведущих нулей, а запись сопряжения — с ними.
// Обе стороны приводим к одному виду: шесть байт, нижний регистр, «aa:bb:…».
static int normalize_mac(const char *raw, char out[18]) {
    unsigned int b[6];
    if (sscanf(raw, "%x:%x:%x:%x:%x:%x", &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) != 6)
        return -1;
    for (int i = 0; i < 6; i++) if (b[i] > 0xff) return -1;
    snprintf(out, 18, "%02x:%02x:%02x:%02x:%02x:%02x",
             b[0], b[1], b[2], b[3], b[4], b[5]);
    return 0;
}

static int mode_mac(const char *udid) {
    char *record = NULL;
    uint32_t size = 0;
    if (usbmuxd_read_pair_record(udid, &record, &size) < 0 || !record || size == 0) {
        fprintf(stderr, "pair record not found\n");
        free(record);
        return 5;
    }
    plist_t root = NULL;
    plist_from_memory(record, size, &root, NULL);
    free(record);
    if (!root) {
        fprintf(stderr, "pair record unreadable\n");
        return 5;
    }
    plist_t node = plist_dict_get_item(root, "WiFiMACAddress");
    char *value = NULL;
    if (node && plist_get_node_type(node) == PLIST_STRING)
        plist_get_string_val(node, &value);
    plist_free(root);
    if (!value) {
        fprintf(stderr, "WiFiMACAddress missing\n");
        return 5;
    }
    char mac[18];
    int ok = normalize_mac(value, mac);
    free(value);
    if (ok != 0) {
        fprintf(stderr, "WiFiMACAddress malformed\n");
        return 5;
    }
    printf("%s\n", mac);
    return 0;
}

// --- addr --------------------------------------------------------------------

static int mode_addr(const char *udid) {
    usbmuxd_device_info_t *list = NULL;
    int count = usbmuxd_get_device_list(&list);
    if (count < 0) {
        fprintf(stderr, "usbmuxd unavailable\n");
        return 5;
    }
    int rc = 5;
    for (int i = 0; i < count; i++) {
        if (strcasecmp(list[i].udid, udid) != 0) continue;
        if (list[i].conn_type != CONNECTION_TYPE_NETWORK) continue;
        // conn_data — сырой sockaddr от usbmuxd: [0] длина, [1] семейство.
        // IPv6 link-local пропускаем: рукопожатие идёт по IPv4.
        const unsigned char *raw = (const unsigned char *)list[i].conn_data;
        if (raw[1] != AF_INET) continue;
        struct in_addr addr;
        memcpy(&addr, raw + 4, sizeof(addr));
        char text[INET_ADDRSTRLEN];
        if (!inet_ntop(AF_INET, &addr, text, sizeof(text))) continue;
        printf("%s\n", text);
        rc = 0;
        break;
    }
    usbmuxd_device_list_free(&list);
    if (rc != 0) fprintf(stderr, "no network address\n");
    return rc;
}


// --- watch -------------------------------------------------------------------

// Телефон появляется в usbmuxd, когда его подключили кабелем или он проснулся
// в сети. Это самый ранний сигнал «что-то изменилось» — приложение по нему
// опрашивает заряд сразу, не дожидаясь таймера (план §18.1).
static void watch_cb(const usbmuxd_event_t *event, void *user_data) {
    (void)user_data;
    switch (event->event) {
        case UE_DEVICE_ADD:
            printf("ADD %s %s\n", event->device.udid,
                   event->device.conn_type == CONNECTION_TYPE_NETWORK ? "network" : "usb");
            break;
        case UE_DEVICE_REMOVE:
            printf("REMOVE %s\n", event->device.udid);
            break;
        default:
            return;
    }
    fflush(stdout);
}

static int mode_watch(void) {
    usbmuxd_subscription_context_t context = NULL;
    if (usbmuxd_events_subscribe(&context, watch_cb, NULL) != 0) {
        fprintf(stderr, "events subscribe failed\n");
        return 5;
    }
    // События приходят в своём потоке внутри libusbmuxd, а этот поток просто
    // ждёт закрытия stdin: когда приложение умрёт, труба закроется и помощник
    // уйдёт вместе с ним, не оставшись висеть сиротой.
    char buffer[64];
    ssize_t n;
    for (;;) {
        n = read(STDIN_FILENO, buffer, sizeof(buffer));
        if (n > 0) continue;
        // Сигнал прерывает read, но труба цела — это не повод уходить (план §10).
        if (n < 0 && errno == EINTR) continue;
        break;
    }
    usbmuxd_events_unsubscribe(context);
    return 0;
}

// -----------------------------------------------------------------------------

static int usage(void) {
    fprintf(stderr,
            "usage: akb-direct battery <ip> <udid> [domain]\n"
            "       akb-direct health <ip|-> <udid>\n"
            "       akb-direct mac <udid>\n"
            "       akb-direct addr <udid>\n"
            "       akb-direct watch\n");
    return 2;
}

int main(int argc, char **argv) {
    if (argc < 2) return usage();
    const char *mode = argv[1];
    if (strcmp(mode, "watch") == 0) return mode_watch();
    if (argc < 3) return usage();
    if (strcmp(mode, "battery") == 0) {
        if (argc < 4) return usage();
        return mode_battery(argv[2], argv[3],
                            argc > 4 ? argv[4] : "com.apple.mobile.battery");
    }
    if (strcmp(mode, "health") == 0) {
        if (argc < 4) return usage();
        return mode_health(argv[2], argv[3]);
    }
    if (strcmp(mode, "mac") == 0) return mode_mac(argv[2]);
    if (strcmp(mode, "addr") == 0) return mode_addr(argv[2]);
    return usage();
}
