.pragma library

// Presentation only: never send translated names back to Mihomo or use them as keys.
function displayName(value) {
    let name = String(value || "");
    const translations = [
        ["Зарубежный VPN", "International VPN"],
        ["Лучший по задержке", "Lowest latency"],
        ["БЕЛЫЕ СПИСКИ", "ALLOWLIST"],
        ["ОБХОД", "BYPASS"],
        ["Нидерланды", "Netherlands"],
        ["Германия", "Germany"],
        ["Беларусь", "Belarus"],
        ["Россия", "Russia"],
        ["Польша", "Poland"],
        ["Швеция", "Sweden"],
        ["Япония", "Japan"],
        ["Литва", "Lithuania"],
        ["США", "United States"]
    ];
    for (const pair of translations)
        name = name.split(pair[0]).join(pair[1]);
    return name;
}

function englishError(message, fallback) {
    if (!message)
        return fallback;
    // The installed system helper may predate the English UI. Translate its
    // existing messages without requiring a privileged binary replacement.
    const legacy = {
        "Не удалось сохранить режим VPN. Системные настройки не подтверждены.": "Could not save the VPN mode. System settings have not been confirmed.",
        "Некорректные настройки Mihomo или сохранённого режима VPN.": "The Mihomo configuration or saved VPN mode is invalid.",
        "Режим VPN уже переключается. Повторите попытку.": "The VPN mode is already changing. Please try again.",
        "Mihomo отклонил настройки. Предыдущий режим сохранён.": "Mihomo rejected the settings. The previous mode has been preserved.",
        "Не удалось запустить Mihomo. Проверьте журнал mihomo.service.": "Could not start Mihomo. Check the mihomo.service journal.",
        "Режим сохранён, но Mihomo его пока не подтвердил. Нажмите перезапуск.": "The VPN mode was saved, but Mihomo has not confirmed it yet. Please try the switch again.",
        "Обновлятор подписки недоступен. Проверьте службу capybara-updater.": "The subscription updater is unavailable. Check capybara-updater.service.",
        "Не удалось связаться с обновлятором подписки.": "Could not connect to the subscription updater.",
        "Не удалось выполнить локальное управление Mihomo. Проверьте установку mihomo-vpn-control и разрешение администратора.": "Could not control Mihomo locally. Check mihomo-vpn-control and administrator authorization."
    };
    return legacy[message] || (/[А-Яа-яЁё]/.test(message) ? fallback : message);
}

function subscriptionError(status) {
    if (!status || !status.error)
        return "";
    // Codes also translate errors persisted by older updater versions.
    const errors = {
        device_limit: "Capybara's device limit has been reached. Remove an unused device in your account or bot, then try again.",
        identity_error: "Could not read the saved device identity. Restore device.json from backup; a new HWID will not be generated automatically.",
        unsupported_client: "Capybara does not support this client's device identification.",
        network_error: "Could not connect to the subscription server due to a network or TLS error.",
        timeout: "The subscription server did not respond in time.",
        invalid_profile: "The subscription returned an empty, unsupported, or invalid server list.",
        placeholder: "Capybara returned a service placeholder instead of VPN servers.",
        too_large: "The subscription exceeds the 8 MiB size limit.",
        validation_failed: "Mihomo rejected the downloaded profile. The saved profile has not been changed.",
        validation_timeout: "Profile validation in Mihomo exceeded 15 seconds.",
        storage_error: "Could not save the profile or update status to disk.",
        config_error: "The subscription updater settings are invalid.",
        busy: "A subscription update is already in progress.",
        apply_failed: "Could not apply the updated provider in Mihomo. Please try again.",
        unavailable: "The subscription updater is unavailable. Check capybara-updater.service.",
        interrupted: "The previous subscription update was interrupted. Please try again."
    };
    if (status.code === "http_error") {
        const match = String(status.error).match(/HTTP\s+(\d{3})/);
        return "The subscription server returned " + (match ? "HTTP " + match[1] : "an HTTP error") + ". Please try again later.";
    }
    return errors[status.code] || englishError(status.error, "Subscription update failed. Please try again.");
}
