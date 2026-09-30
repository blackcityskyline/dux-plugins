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
    return /[А-Яа-яЁё]/.test(message) ? fallback : message;
}
