import Foundation

/// Only explicitly labelled usage cards enter native code. Generic account
/// pages, model availability, marketing allowances and chat messages never
/// become quota percentages.
struct QuotaPageCapture {
    var signedIn: Bool
    var foundUsage: Bool
    var windows: [UsageWindow]
    var measuredAt: Date
    var account: String?
    static func parse(_ value: [String: Any], at now: Date) -> QuotaPageCapture {
        var windows: [UsageWindow] = [], seen = Set<String>()
        for row in (value["meters"] as? [[String: Any]] ?? []).prefix(64) {
            guard let label = row["label"] as? String, !label.isEmpty, label.count <= 160 else { continue }
            let relative = ClaudeProvider.number(row["resetInSeconds"]).flatMap { $0.isFinite && (0...31_622_400).contains($0) ? now.addingTimeInterval($0) : nil }
            let reset = ClaudeProvider.isoDate(row["resetsAt"]) ?? relative
            let unlimited = row["isUnlimited"] as? Bool == true
            let percent = ClaudeProvider.number(row["percent"])
            let direction = row["direction"] as? String
            if percent != nil {
                guard let percent, percent.isFinite, (0...100).contains(percent), ["used", "remaining"].contains(direction ?? "") else { continue }
            } else if row["percent"] != nil || (!unlimited && reset == nil) { continue }
            let id = String(label.lowercased().prefix(160))
            guard seen.insert(id).inserted else { continue }
            var window = UsageWindow(label: label, usedPercent: percent.map { direction == "remaining" ? 100 - $0 : $0 }, resetsAt: reset, id: id, isUnlimited: unlimited)
            window.measuredAt = now
            windows.append(window)
        }
        let account = (value["account"] as? String).flatMap { $0.count == 64 && $0.allSatisfy { $0.isHexDigit } ? $0 : nil }
        return QuotaPageCapture(signedIn: value["signedIn"] as? Bool == true, foundUsage: value["foundUsage"] as? Bool == true, windows: windows, measuredAt: now, account: account)
    }
    static let script = #"""
        const visible = e => !!(e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden');
        const forbidden = '[data-message-id], [data-testid*="conversation"], .conversation-container, .response-container, message-content, user-query, model-response';
        const quotaTitle = /^(usage(?: limits)?|model quotas?|quota(?:s)?|ChatGPT Chat(?: usage| limits)?|kullanım(?: limitleri)?|model kotaları|kota(?:lar)?)$/i;
        const headings = [...document.querySelectorAll('h1,h2,h3,[role="heading"]')].filter(e => visible(e) && !e.closest(forbidden) && quotaTitle.test((e.innerText || '').trim()));
        const cards = [];
        for (const heading of headings) {
            let card = heading.closest('[role="dialog"],[role="region"],[role="tabpanel"],section');
            if (!card) card = heading.parentElement;
            if (!card || card === document.body || card.querySelector(forbidden)) continue;
            if (!cards.includes(card)) cards.push(card);
        }
        const accountElement = [...document.querySelectorAll('button,a,[role="button"]')].find(e => {
            const label = (e.getAttribute('aria-label') || '').trim();
            return visible(e) && /^(Google Account|Google Hesabı|Account menu|Hesap menüsü|Open profile menu)/i.test(label);
        });
        const signedIn = !!accountElement;
        const accountLabel = accountElement?.getAttribute('aria-label') || '';
        const email = accountLabel.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i)?.[0];
        let account = null;
        if (email && crypto.subtle) {
            const digest = await crypto.subtle.digest('SHA-256',new TextEncoder().encode(email.toLowerCase()));
            account = [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2,'0')).join('');
        }
        const meters = [];
        for (const card of cards.slice(0,8)) {
            const lines = (card.innerText || '').slice(0,12000).split('\n').map(s => s.trim()).filter(Boolean);
            let pool = headings.some(h => card.contains(h) && /^ChatGPT Chat/i.test(h.innerText)) ? 'ChatGPT Chat' : '', label = '';
            for (let i = 0; i < lines.length && meters.length < 64; i++) {
                const line = lines[i];
                if (/^(Gemini Models|Claude and GPT models|Cursor Models|Other Models)$/i.test(line)) { pool = line; label = ''; continue; }
                if (/(five.hour|5.hour|weekly|session|beş saat|5 saat|haftalık|oturum)/i.test(line) && !/\d+(?:[.,]\d+)?\s*%/.test(line)) label = line.slice(0,100);
                const match = line.match(/(\d+(?:[.,]\d+)?)\s*%/) || line.match(/%\s*(\d+(?:[.,]\d+)?)/);
                if (!match) continue;
                const hasPercent = text => /\d+(?:[.,]\d+)?\s*%|%\s*\d+(?:[.,]\d+)?/.test(text);
                const context = [i>0 && !hasPercent(lines[i-1]) ? lines[i-1] : '',line,!hasPercent(lines[i+1] || '') ? lines[i+1] || '' : ''].join(' ');
                const remaining = /remaining|kalan/i.test(context), used = /used|consumed|kullanıl|kullanılan|tüketil/i.test(context);
                if (remaining === used) continue;
                const inline = line.replace(/\d+(?:[.,]\d+)?\s*%|%\s*\d+(?:[.,]\d+)?/g,'').replace(/remaining|used|consumed|kalan|kullanılan/gi,'').trim();
                const inlineWindow = /(five.hour|5.hour|weekly|session|beş saat|5 saat|haftalık|oturum)/i.test(inline);
                const title = [pool,inlineWindow ? inline : label || inline].filter(Boolean).join(' · ').slice(0,160);
                if (!title || quotaTitle.test(title)) continue;
                const meter = {label:title,percent:Number(match[1].replace(',','.')),direction:remaining?'remaining':'used'};
                for (const hint of lines.slice(i+1,i+5)) {
                    if (hasPercent(hint) || /(five.hour|5.hour|weekly|session|haftalık|oturum)/i.test(hint)) break;
                    if (!/^resets(?: in)?|^yenilenme|^yenilenir/i.test(hint)) continue;
                    const parts = [...hint.matchAll(/(\d+)\s*(days?|hours?|min(?:utes?)?|sec(?:onds?)?|gün|sa|dk|sn|d|h|m|s)\b/gi)];
                    if (!parts.length) continue;
                    meter.resetInSeconds = parts.reduce((sum,p) => {
                        const unit = p[2].toLowerCase();
                        return sum + Number(p[1]) * (unit==='gün' || unit.startsWith('d') ? 86400 : unit==='sa' || unit.startsWith('h') ? 3600 : unit==='dk' || unit.startsWith('m') ? 60 : 1);
                    },0);
                    break;
                }
                meters.push(meter);
            }
        }
        return {signedIn,foundUsage:cards.length>0,meters,account};
        """#
    static let openGoogleUsage = #"""
        const visible = e => !!(e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden');
        const blocked = '[data-message-id], .conversation-container, .response-container, user-query, model-response';
        const find = regex => [...document.querySelectorAll('button,a,[role="button"],[role="menuitem"]')].find(e => visible(e) && !e.closest(blocked) && regex.test((e.getAttribute('aria-label') || e.innerText || '').trim()));
        const usage = /^(Usage limits|Model quotas?|Kullanım limitleri|Model kotaları)$/i;
        if ([...document.querySelectorAll('h1,h2,h3,[role="heading"]')].some(e => visible(e) && usage.test((e.innerText || '').trim()))) return true;
        let button = find(usage);
        if (!button) {
            const settings = find(/^(Settings(?: and help)?|Ayarlar(?: ve yardım)?)$/i);
            if (settings) { settings.click(); await new Promise(r => setTimeout(r,400)); button = find(usage); }
        }
        if (button) { button.click(); await new Promise(r => setTimeout(r,1000)); return true; }
        return false;
        """#
}
