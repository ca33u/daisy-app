//
//  BrandTransliterations.swift
//  Daisy
//
//  Built-in "product names in Latin" layer for dictation (Egor,
//  2026-07-25). Parakeet (and to a lesser degree Whisper/Apple) writes
//  English brand names in the script of the dominant speech language —
//  Russian dictation yields «фигма», «гитхаб», «зум». This table maps
//  curated Cyrillic transliteration STEMS back to the canonical Latin
//  name, inflected forms included («в фигме» → «в Figma»).
//
//  Design constraints:
//    • CURATED list only — generic transliteration is wrong more often
//      than right («джира» → "dzhira"). Every stem here was checked
//      against real Russian words; ambiguous ones are deliberately
//      absent (мир/Miro, канва/Canva, асана/Asana, редис/Redis,
//      питон/Python, курсор/Cursor, хром/Chrome…).
//    • Matching is stem + a whitelist of Russian CASE ENDINGS, bounded
//      by non-Cyrillic on both sides. The ending whitelist (not a
//      greedy [а-яё]{0,3}) is what keeps «зуммер» from becoming
//      "Zoomмер" and «телеграмма» from becoming "Telegramма".
//    • The user's own Vocabulary rules always win: any built-in whose
//      stem collides with a user trigger is skipped for that run.
//    • Applied only in the dictation paste path, gated by
//      Settings → Transcription → "Fix product names" (default ON).
//

import Foundation

nonisolated enum BrandCorrections {

    /// UserDefaults key for the Settings toggle. Read directly (with a
    /// `true` default) by DictationPaste — mirrors the
    /// `AppSettings.fixBrandNamesInDictation` property.
    static let defaultsKey = "daisy.fixBrandNamesInDictation"

    /// One brand: canonical spelling + the Cyrillic stems that
    /// dictation engines produce for it. `latin` is historical naming —
    /// it holds the CANONICAL form, which for Russian brands is their
    /// proper Cyrillic casing («сбербанк» → «Сбербанк», «т банк» →
    /// «Т-Банк») and for everything else the Latin name.
    struct Entry {
        let latin: String
        let stems: [String]
    }

    /// Curated table. Stems are lowercase, WITHOUT case endings.
    static let entries: [Entry] = [
        Entry(latin: "Figma",      stems: ["фигм"]),
        Entry(latin: "FigJam",     stems: ["фигджем", "фигджам"]),
        Entry(latin: "Zoom",       stems: ["зум"]),
        Entry(latin: "Slack",      stems: ["слак", "слэк"]),
        Entry(latin: "Notion",     stems: ["ноушн", "ноушен"]),
        Entry(latin: "GitHub",     stems: ["гитхаб", "гитхап"]),
        Entry(latin: "GitLab",     stems: ["гитлаб"]),
        Entry(latin: "Jira",       stems: ["джир"]),
        Entry(latin: "Trello",     stems: ["трелл"]),
        Entry(latin: "Linear",     stems: ["линеар", "линиар"]),
        Entry(latin: "Obsidian",   stems: ["обсидиан"]),
        Entry(latin: "Telegram",   stems: ["телеграм"]),
        Entry(latin: "Discord",    stems: ["дискорд"]),
        Entry(latin: "WhatsApp",   stems: ["ватсап", "вотсап", "уотсап"]),
        Entry(latin: "YouTube",    stems: ["ютуб", "ютьюб"]),
        Entry(latin: "Google",     stems: ["гугл"]),
        Entry(latin: "Gmail",      stems: ["джимейл", "гмейл", "джимэйл"]),
        Entry(latin: "Excel",      stems: ["эксель", "иксель"]),
        Entry(latin: "Word",       stems: ["ворд"]),
        Entry(latin: "PowerPoint", stems: ["поверпоинт", "паверпоинт"]),
        Entry(latin: "Outlook",    stems: ["аутлук"]),
        Entry(latin: "Keynote",    stems: ["кейнот"]),
        Entry(latin: "Docker",     stems: ["докер"]),
        Entry(latin: "Kubernetes", stems: ["кубернетес", "кубернетис"]),
        Entry(latin: "React",      stems: ["реакт"]),
        Entry(latin: "Angular",    stems: ["ангуляр"]),
        Entry(latin: "Postgres",   stems: ["постгрес"]),
        Entry(latin: "MongoDB",    stems: ["монгодб", "монгодиби"]),
        Entry(latin: "Anthropic",  stems: ["антропик", "энтропик"]),
        Entry(latin: "Claude",     stems: ["клод"]),
        Entry(latin: "OpenAI",     stems: ["опенай", "опенэйай", "оупенай"]),
        Entry(latin: "ChatGPT",    stems: ["чатгпт", "чатжпт", "чатджипити"]),
        Entry(latin: "Gemini",     stems: ["джемини", "гемини"]),
        Entry(latin: "Copilot",    stems: ["копайлот", "копилот"]),
        Entry(latin: "Xcode",      stems: ["икскод", "экскод"]),
        Entry(latin: "TestFlight", stems: ["тестфлайт"]),
        Entry(latin: "Whisper",    stems: ["виспер", "уиспер"]),
        Entry(latin: "Zapier",     stems: ["запиер", "зейпиер"]),
        Entry(latin: "Airtable",   stems: ["эйртейбл", "эртейбл"]),
        Entry(latin: "Dropbox",    stems: ["дропбокс"]),
        Entry(latin: "iCloud",     stems: ["айклауд"]),
        Entry(latin: "iPhone",     stems: ["айфон"]),
        Entry(latin: "iPad",       stems: ["айпад", "айпэд"]),
        Entry(latin: "MacBook",    stems: ["макбук"]),
        Entry(latin: "Instagram",  stems: ["инстаграм"]),
        Entry(latin: "TikTok",     stems: ["тикток"]),
        Entry(latin: "LinkedIn",   stems: ["линкедин", "линкдин"]),
        Entry(latin: "Facebook",   stems: ["фейсбук", "фэйсбук"]),
        Entry(latin: "Twitter",    stems: ["твиттер", "твитер"]),
        Entry(latin: "Reddit",     stems: ["реддит", "редит"]),
        Entry(latin: "Spotify",    stems: ["спотифай"]),
        Entry(latin: "Netflix",    stems: ["нетфликс"]),
        Entry(latin: "Stripe",     stems: ["страйп"]),
        Entry(latin: "PayPal",     stems: ["пейпал", "пэйпал", "пейпэл"]),
        Entry(latin: "Shopify",    stems: ["шопифай"]),
        Entry(latin: "Webflow",    stems: ["вебфлоу", "вэбфлоу"]),
        Entry(latin: "WordPress",  stems: ["вордпресс", "вордпрес"]),
        Entry(latin: "Vercel",     stems: ["версел", "верцел"]),
        Entry(latin: "Supabase",   stems: ["супабейс", "супабейз"]),
        Entry(latin: "Firebase",   stems: ["файербейс", "фаербейс", "файрбейс"]),
        Entry(latin: "HubSpot",    stems: ["хабспот"]),
        Entry(latin: "JavaScript", stems: ["джаваскрипт"]),
        Entry(latin: "TypeScript", stems: ["тайпскрипт"]),
        Entry(latin: "Kotlin",     stems: ["котлин"]),
        Entry(latin: "Linux",      stems: ["линукс"]),
        Entry(latin: "Windows",    stems: ["виндоус", "виндовс"]),
        Entry(latin: "Android",    stems: ["андроид"]),
        Entry(latin: "macOS",      stems: ["макос"]),
        // ── 2026-07-25 expansion (Egor): platforms, hardware, popular
        // apps. Same curation bar — every stem checked against real
        // Russian words. Deliberately absent: Uber («убери» = убер+и!),
        // Siri («Сирия» = сири+я!), Signal («сигнал»), Blender, Sketch
        // («скетч»), Premiere («премьер»), Kafka («Кафка»), Electron
        // («электрон»), Llama («лама»), Яндекс/VK/Ozon (canonical
        // Russian spelling IS Cyrillic). Tesla included — the physics
        // unit is rare in speech, the company isn't.
        Entry(latin: "Apple",      stems: ["эпл", "эппл", "эйпл"]),
        Entry(latin: "iOS",        stems: ["айос"]),
        Entry(latin: "AirPods",    stems: ["эйрподс", "эйрпод", "аирподс", "аирпод"]),
        Entry(latin: "HomePod",    stems: ["хоумпод", "хомпод"]),
        Entry(latin: "FaceTime",   stems: ["фейстайм", "фэйстайм"]),
        Entry(latin: "iMessage",   stems: ["аймесседж", "аймессадж"]),
        Entry(latin: "Finder",     stems: ["файндер", "фаиндер"]),
        Entry(latin: "Microsoft",  stems: ["майкрософт", "микрософт"]),
        Entry(latin: "Samsung",    stems: ["самсунг"]),
        Entry(latin: "Amazon",     stems: ["амазон"]),
        Entry(latin: "Intel",      stems: ["интел"]),
        Entry(latin: "Nvidia",     stems: ["нвидиа", "нвидия", "энвидиа"]),
        Entry(latin: "Tesla",      stems: ["тесл"]),
        Entry(latin: "Firefox",    stems: ["файрфокс", "фаерфокс", "файерфокс"]),
        Entry(latin: "Ubuntu",     stems: ["убунту"]),
        Entry(latin: "Photoshop",  stems: ["фотошоп"]),
        Entry(latin: "Lightroom",  stems: ["лайтрум"]),
        Entry(latin: "Wi-Fi",      stems: ["вайфай"]),
        Entry(latin: "Bluetooth",  stems: ["блютус", "блютуз"]),
        Entry(latin: "Viber",      stems: ["вайбер"]),
        Entry(latin: "Skype",      stems: ["скайп"]),
        Entry(latin: "Twitch",     stems: ["твич"]),
        Entry(latin: "Steam",      stems: ["стим"]),
        Entry(latin: "PlayStation", stems: ["плейстейшн", "плэйстейшн", "плейстешн"]),
        Entry(latin: "Xbox",       stems: ["иксбокс", "хбокс"]),
        Entry(latin: "Nintendo",   stems: ["нинтендо"]),
        Entry(latin: "Duolingo",   stems: ["дуолинго"]),
        Entry(latin: "Booking",    stems: ["букинг"]),
        Entry(latin: "Airbnb",     stems: ["эйрбнб", "аирбнб", "эйрбиэнби"]),
        Entry(latin: "Grok",       stems: ["грок"]),
        Entry(latin: "Midjourney", stems: ["миджорни", "миджёрни", "миджурни"]),
        Entry(latin: "Perplexity", stems: ["перплексити"]),
        Entry(latin: "DeepSeek",   stems: ["дипсик"]),
        Entry(latin: "Tailwind",   stems: ["тейлвинд", "тэйлвинд"]),
        Entry(latin: "Django",     stems: ["джанго"]),
        Entry(latin: "Flutter",    stems: ["флаттер"]),
        Entry(latin: "Unity",      stems: ["юнити"]),
        Entry(latin: "Unreal",     stems: ["анрил", "анриал"]),
        Entry(latin: "Grafana",    stems: ["графан"]),
        Entry(latin: "Sentry",     stems: ["сентри"]),
        Entry(latin: "Cloudflare", stems: ["клаудфлер", "клаудфлэр", "клаудфлеар"]),
        Entry(latin: "Heroku",     stems: ["хероку", "героку"]),
        Entry(latin: "Confluence", stems: ["конфлюенс", "конфлуенс"]),
        Entry(latin: "Atlassian",  stems: ["атлассиан", "атласиан"]),
        Entry(latin: "Datadog",    stems: ["датадог"]),
        Entry(latin: "Grammarly",  stems: ["граммарли", "грамарли"]),
        Entry(latin: "Pinterest",  stems: ["пинтерест"]),
        Entry(latin: "Snapchat",   stems: ["снепчат", "снэпчат"]),
        Entry(latin: "Threads",    stems: ["тредс"]),
        Entry(latin: "Oracle",     stems: ["оракл"]),
        Entry(latin: "Salesforce", stems: ["сейлсфорс", "сэйлсфорс"]),
        // ── 2026-07-25, Russian brands (Egor): here the fix is
        // NORMALIZATION — proper casing/hyphenation of the canonical
        // Cyrillic name («т банк» → «Т-Банк»), or the Latin name where
        // that's the brand's canonical form (Wildberries, Rutube,
        // HeadHunter). Deliberately absent after the usual collision
        // pass: Ozon («озон» = gas), Мир (карта), Точка («точка»!),
        // Контур, Магнит, Самокат, Дзен, Мегафон («в мегафон»),
        // Пятёрочка («на пятёрочку»), Kaspi («Каспия» = каспи+я!),
        // «в контакте» раздельно (легитимная фраза — only the joined
        // «вконтакте» maps), «тиньков» (фамилия).
        Entry(latin: "Т-Банк",     stems: ["т банк", "тбанк", "тэ банк"]),
        Entry(latin: "Тинькофф",   stems: ["тинькофф", "тинькоф"]),
        Entry(latin: "Сбербанк",   stems: ["сбербанк"]),
        Entry(latin: "Сбер",       stems: ["сбер"]),
        Entry(latin: "Альфа-Банк", stems: ["альфа банк", "альфабанк"]),
        Entry(latin: "ВТБ",        stems: ["втб"]),
        Entry(latin: "Райффайзен", stems: ["райффайзен", "райфайзен"]),
        Entry(latin: "Модульбанк", stems: ["модульбанк"]),
        Entry(latin: "ЮMoney",     stems: ["юмани"]),
        Entry(latin: "МТС",        stems: ["мтс"]),
        Entry(latin: "Билайн",     stems: ["билайн"]),
        Entry(latin: "Ростелеком", stems: ["ростелеком"]),
        Entry(latin: "Госуслуги",  stems: ["госуслуг"]),
        Entry(latin: "Авито",      stems: ["авито"]),
        Entry(latin: "Яндекс",     stems: ["яндекс"]),
        Entry(latin: "Wildberries", stems: ["вайлдберриз", "вайлдберис", "вайлдбериз"]),
        Entry(latin: "Rutube",     stems: ["рутуб"]),
        Entry(latin: "Хабр",       stems: ["хабр"]),
        Entry(latin: "Кинопоиск",  stems: ["кинопоиск"]),
        Entry(latin: "ВКонтакте",  stems: ["вконтакте"]),
        Entry(latin: "СДЭК",       stems: ["сдэк", "сдек"]),
        Entry(latin: "Циан",       stems: ["циан"]),
        Entry(latin: "HeadHunter", stems: ["хедхантер", "хэдхантер"]),
        Entry(latin: "2ГИС",       stems: ["двагис", "два гис"]),
        Entry(latin: "1С",         stems: ["один эс", "одинэс"]),
    ]

    /// Russian case endings we accept after a stem. A WHITELIST, not a
    /// greedy wildcard — «зуммер» (зум + мер) and «телеграмма»
    /// (телеграм + ма) must NOT match.
    private static let caseEndings = [
        "а", "е", "у", "ы", "и", "я", "ю", "ой", "ом", "ем", "ов", "ам",
        "ами", "ах", "ях",
    ]
    private static let endings = "(?:" + caseEndings.joined(separator: "|") + ")?"

    /// Single-token lookup: every Cyrillic rendering we know (a stem plus
    /// one accepted case ending) AND the canonical spelling itself map to
    /// the SAME key.
    ///
    /// Built for `TranscriptPolisher`, which needs «фигму» and "Figma" to
    /// compare equal rather than as two unrelated words. Measuring a
    /// Russian transcript's polish without this table charged a token for
    /// every brand the model spelled correctly, while the identical fix in
    /// English ("figma" → "Figma") was free under case-folding — an
    /// asymmetry that made real Russian chunks fail a budget English ones
    /// sailed through.
    ///
    /// Only single-token KEYS participate — multi-word stems («т банк»,
    /// «альфа банк») can never equal one token. A hyphenated canonical
    /// still earns an entry through its punctuation-stripped form:
    /// «вайфай» → "wifi" and «тбанк» → "тбанк" are the single tokens a
    /// transcript actually contains, and dropping the whole brand for
    /// the sake of its dash would leave exactly the Russian asymmetry
    /// this table exists to remove.
    static let canonicalFolds: [String: String] = {
        func singleToken(_ s: String) -> Bool {
            !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber }
        }
        func key(for latin: String) -> String? {
            // The canonical may carry a dash; it may not carry a space,
            // since a two-word name is two tokens no matter what.
            guard !latin.contains(" ") else { return nil }
            let stripped = latin.lowercased().filter { $0.isLetter || $0.isNumber }
            return stripped.isEmpty ? nil : stripped
        }
        var folds: [String: String] = [:]
        for entry in entries {
            guard let canonical = key(for: entry.latin) else { continue }
            for stem in entry.stems where singleToken(stem) {
                folds[stem] = canonical
                for ending in caseEndings {
                    folds[stem + ending] = canonical
                }
            }
        }
        // Canonicals last so a stem of one brand can never shadow another
        // brand's own name.
        for entry in entries {
            guard let canonical = key(for: entry.latin) else { continue }
            folds[canonical] = canonical
        }
        return folds
    }()

    /// One compiled regex per entry (all stems alternated), built once.
    /// Bounded by "no Cyrillic letter" on both sides so stems can't
    /// match inside longer Russian words.
    private static let compiled: [(latin: String, regex: NSRegularExpression)] = {
        entries.compactMap { entry in
            let alternation = entry.stems
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            let pattern = "(?<![а-яё])(?:\(alternation))\(endings)(?![а-яё])"
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]
            ) else { return nil }
            return (entry.latin, regex)
        }
    }()

    /// Replace transliterated brand mentions with their Latin names.
    /// `userTriggers` — lowercased `from`-strings of the user's own
    /// Vocabulary rules; any built-in stem that appears among them is
    /// skipped so the user's rule (already applied upstream) stays
    /// authoritative even when it maps to a different target.
    static func apply(to text: String, userTriggers: Set<String>) -> (text: String, fixes: Int) {
        guard !text.isEmpty else { return (text, 0) }
        var result = text
        var fixes = 0
        for (latin, regex) in compiled {
            // Respect user rules: if any stem of this entry is a prefix
            // of a user trigger (or equal), the user owns this brand.
            let stems = entries.first(where: { $0.latin == latin })?.stems ?? []
            if stems.contains(where: { stem in
                userTriggers.contains(where: { $0.hasPrefix(stem) })
            }) { continue }
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.numberOfMatches(in: result, options: [], range: range)
            guard matches > 0 else { continue }
            result = regex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: latin
            )
            fixes += matches
        }
        return (result, fixes)
    }

    /// Post-polish brand-restoration detector (auto-suggest layer).
    /// When the voice-polish LLM restored a Latin name we DON'T cover
    /// (not in this table, not in the user's rules), surface it so one
    /// tap turns it into a permanent Vocabulary correction — after
    /// which it works on every engine, polish enabled or not.
    ///
    /// Heuristic on purpose: exactly one new Latin token in the
    /// polished text + exactly one dropped Cyrillic token of plausible
    /// length → treat as a restoration pair. Anything murkier returns
    /// nil; a missed suggestion costs nothing.
    static func suggestRestoredBrand(
        original: String,
        polished: String,
        userTriggers: Set<String>
    ) -> (from: String, to: String)? {
        func tokens(_ s: String) -> [String] {
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let origTokens = Set(tokens(original))
        let polishedTokens = Set(tokens(polished))

        let newLatin = polishedTokens.subtracting(origTokens).filter { tok in
            tok.count >= 4 && tok.allSatisfy { $0.isASCII && $0.isLetter }
        }
        let lostCyrillic = origTokens.subtracting(polishedTokens).filter { tok in
            tok.count >= 4 && tok.unicodeScalars.allSatisfy { ("а"..."я").contains(Character($0)) || $0 == "ё" }
        }
        guard newLatin.count == 1, lostCyrillic.count == 1,
              let to = newLatin.first, let from = lostCyrillic.first else { return nil }

        // Length sanity — a transliteration is in the same ballpark.
        guard to.count * 2 >= from.count, from.count * 2 >= to.count else { return nil }

        // Already covered? Then the suggestion is noise.
        if userTriggers.contains(where: { from.hasPrefix($0) || $0.hasPrefix(from) }) { return nil }
        if entries.contains(where: { $0.stems.contains(where: { from.hasPrefix($0) }) }) { return nil }

        // Restore the canonical casing the model produced (the token set
        // was lowercased) by finding the original-cased token.
        let cased = polished
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .first(where: { $0.lowercased() == to }) ?? to
        return (from: from, to: cased)
    }
}
