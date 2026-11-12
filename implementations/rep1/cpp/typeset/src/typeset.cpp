#include "typeset/typeset.hpp"

#include <deque>

namespace typeset {

Resources Resources::load(const std::string& dataDir) {
    return Resources{FontSet::load(dataDir), PatternSet::load(dataDir, "english"), PatternSet::load(dataDir, "minimal")};
}

Result run(const Input& input, const std::string& dataDir) {
    Result r;
    if (!input.document) {
        r.error = "-:0:0: missing-document\n";
        return r;
    }
    // Validate the input before touching the data files.
    try {
        Settings::parse(input.settings ? std::optional<std::string_view>(*input.settings) : std::nullopt);
        Document::parse(*input.document);
    } catch (const Error& e) {
        r.error = e.format() + "\n";
        return r;
    }
    return run(input, Resources::load(dataDir));
}

namespace {

std::string chapterText(const std::vector<HeadingInfo>& headings, int id) {
    if (id < 0) return "";
    const HeadingInfo& h = headings[id];
    return h.number.empty() ? h.plain : h.number + " " + h.plain;
}

/// Substitute placeholders of one header/footer slot.
std::string substitute(const Text& text, const std::string& page, i64 pages, const Document& doc,
                       const std::string& chapter, const std::string& section) {
    std::string out;
    for (const TextPart& p : text) {
        if (!p.placeholder) out += p.text;
        else if (p.text == "page") out += page;
        else if (p.text == "pages") out += std::to_string(pages);
        else if (p.text == "title") out += doc.title;
        else if (p.text == "author") out += doc.author;
        else if (p.text == "date") out += doc.date;
        else if (p.text == "chapter") out += chapter;
        else if (p.text == "section") out += section;
    }
    return out;
}

}  // namespace

Result run(const Input& input, const Resources& res) {
    Result r;
    if (!input.document) {
        r.error = "-:0:0: missing-document\n";
        return r;
    }
    Settings settings;
    Document doc;
    try {
        settings = Settings::parse(input.settings ? std::optional<std::string_view>(*input.settings) : std::nullopt);
        doc = Document::parse(*input.document);
    } catch (const Error& e) {
        r.error = e.format() + "\n";
        return r;
    }

    const PatternSet& patterns = settings.hyphenPatterns == "minimal" ? res.minimal : res.english;
    Stats stats;
    Layouter layouter(settings, res.fonts, patterns, stats);
    BodyLayout body = layouter.layoutBody(doc);

    PaginateInput bodyIn{body.list, &body.figures, &body.footnoteLines, &body.headings};
    std::vector<PageRecord> bodyPages = paginate(settings, res.fonts, stats, bodyIn);

    std::vector<PageRecord> frontPages;
    if (doc.hasToc) {
        std::vector<TocEntry> entries;
        for (const HeadingInfo& h : body.headings) {
            if (!h.inToc) continue;
            entries.push_back({h.level, h.number, h.plain, std::to_string(settings.pageStart + h.page - 1)});
        }
        std::string title = doc.tocTitle ? *doc.tocTitle : settings.tocTitle;
        VList toc = layouter.layoutToc(title, entries);
        PaginateInput tocIn{toc, nullptr, nullptr, nullptr};
        frontPages = paginate(settings, res.fonts, stats, tocIn);
    }

    // Running headers and footers
    HListBuilder builder(settings, res.fonts, patterns);
    const i64 bodyCount = static_cast<i64>(bodyPages.size());
    std::vector<OutputPage> out;
    auto finish = [&](PageRecord& rec, const std::string& label, i64 labelValue, bool front) {
        OutputPage page;
        page.label = label;
        page.items = std::move(rec.items);
        std::string chapter = front ? "" : chapterText(body.headings, rec.chapter);
        std::string section = front ? "" : chapterText(body.headings, rec.section);
        const auto& slots = labelValue % 2 == 0 ? settings.slotsEven : settings.slotsOdd;
        for (int slot = 0; slot < SlotCount; ++slot) {
            std::string text = substitute(slots[slot], label, bodyCount, doc, chapter, section);
            if (text.empty()) continue;
            Context c;
            c.family = settings.headerFont;
            c.size = settings.headerSize;
            c.align = Align::Left;
            c.hyphenate = false;
            HList h = builder.build(plainUnits(text), std::vector<StyleNode>{StyleNode{}}, c);
            i64 W = 0;
            for (const Item& it : h.items)
                if (it.kind == Item::Box || (it.kind == Item::Glue && !it.infinite)) W += it.width;
            bool anyText = false;
            for (const Item& it : h.items) anyText = anyText || (it.kind == Item::Box && !it.rigid);
            if (!anyText) continue;
            const bool header = slot < 3;
            i64 x = settings.bodyX();
            if (slot % 3 == 1) x += floorDiv(settings.bodyWidth() - W, 2);
            else if (slot % 3 == 2) x += settings.bodyWidth() - W;
            for (const Item& it : h.items) {
                if (it.kind == Item::Box && !it.rigid) {
                    OutItem o;
                    o.kind = OutItem::Text;
                    o.region = header ? Region::Header : Region::Footer;
                    o.face = it.face;
                    o.size = it.size;
                    o.x = x;
                    o.y = header ? settings.headerBaseline : settings.footerBaseline;
                    o.width = it.width;
                    o.text = it.text;
                    page.items.push_back(std::move(o));
                }
                if (it.kind == Item::Box || (it.kind == Item::Glue && !it.infinite)) x += it.width;
            }
        }
        out.push_back(std::move(page));
    };
    for (std::size_t m = 0; m < frontPages.size(); ++m)
        finish(frontPages[m], toRoman(static_cast<i64>(m) + 1), static_cast<i64>(m) + 1, true);
    for (std::size_t m = 0; m < bodyPages.size(); ++m) {
        i64 label = settings.pageStart + static_cast<i64>(m);
        finish(bodyPages[m], std::to_string(label), label, false);
    }

    stats.pages = static_cast<i64>(out.size());
    stats.frontPages = static_cast<i64>(frontPages.size());
    r.ok = true;
    r.layout = formatLayout(out, settings);
    r.report = formatReport(stats);
    r.stats = stats;
    return r;
}

}  // namespace typeset
