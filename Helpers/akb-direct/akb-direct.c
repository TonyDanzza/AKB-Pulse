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
//   akb-direct mac <udid>            WiFiMACAddress из записи сопряжения
//   akb-direct addr <udid>           IPv4, если usbmuxd видит телефон по сети
//
// Коды возврата: 0 ок, 2 неверные аргументы, 3 рукопожатие не удалось
// (телефон спит/недоступен), 4 GetValue не удался, 5 не найдено.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
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

// --- battery -----------------------------------------------------------------

static int mode_battery(const char *ip, const char *udid, const char *domain) {
    struct sockaddr_in *sa = calloc(1, sizeof(*sa));
    if (!sa) return 4;
    sa->sin_family = AF_INET;
    sa->sin_len = sizeof(*sa);
    sa->sin_port = 0;
    if (inet_pton(AF_INET, ip, &sa->sin_addr) != 1) {
        fprintf(stderr, "bad ip\n");
        free(sa);
        return 2;
    }
    struct idevice_private *dev = calloc(1, sizeof(*dev));
    if (!dev) { free(sa); return 4; }
    dev->udid = strdup(udid);
    dev->conn_type = CONNECTION_NETWORK;
    dev->conn_data = sa;

    lockdownd_client_t client = NULL;
    lockdownd_error_t lerr =
        lockdownd_client_new_with_handshake((idevice_t)dev, &client, "AKB");
    if (lerr != LOCKDOWN_E_SUCCESS) {
        fprintf(stderr, "lockdown handshake failed: %d\n", lerr);
        return 3;
    }
    plist_t val = NULL;
    lerr = lockdownd_get_value(client, domain, NULL, &val);
    if (lerr != LOCKDOWN_E_SUCCESS || !val) {
        fprintf(stderr, "get_value failed: %d\n", lerr);
        lockdownd_client_free(client);
        return 4;
    }
    plist_dict_iter it = NULL;
    plist_dict_new_iter(val, &it);
    char *key = NULL;
    plist_t node = NULL;
    while (1) {
        plist_dict_next_item(val, it, &key, &node);
        if (!key) break;
        print_node(key, node);
        free(key);
        key = NULL;
    }
    free(it);
    plist_free(val);
    lockdownd_client_free(client);
    return 0;
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

// -----------------------------------------------------------------------------

static int usage(void) {
    fprintf(stderr,
            "usage: akb-direct battery <ip> <udid> [domain]\n"
            "       akb-direct mac <udid>\n"
            "       akb-direct addr <udid>\n");
    return 2;
}

int main(int argc, char **argv) {
    if (argc < 3) return usage();
    const char *mode = argv[1];
    if (strcmp(mode, "battery") == 0) {
        if (argc < 4) return usage();
        return mode_battery(argv[2], argv[3],
                            argc > 4 ? argv[4] : "com.apple.mobile.battery");
    }
    if (strcmp(mode, "mac") == 0) return mode_mac(argv[2]);
    if (strcmp(mode, "addr") == 0) return mode_addr(argv[2]);
    return usage();
}
