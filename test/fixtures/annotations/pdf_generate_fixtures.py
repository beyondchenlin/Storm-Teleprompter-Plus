"""Generate synthetic, original PDF annotation fixtures (not WPS exports).

Development-only requirements: PyMuPDF 1.26.6 and DejaVu Sans. Neither is
included in the application. Run from any directory:
  python test/fixtures/annotations/pdf_generate_fixtures.py
Set PDF_FIXTURE_EMOJI_FONT to a font with U+1F600 when the default font is absent.
"""

from pathlib import Path
import json
import os

import fitz


ROOT = Path(__file__).resolve().parent
EMOJI_FONT = Path(
    os.environ.get(
        "PDF_FIXTURE_EMOJI_FONT", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
    )
)
if not EMOJI_FONT.is_file() or not fitz.Font(fontfile=str(EMOJI_FONT)).has_glyph(0x1F600):
    raise RuntimeError("Provide a font containing U+1F600 through PDF_FIXTURE_EMOJI_FONT")


def stamp(doc):
    doc.set_metadata(
        {
            "title": "合成批注测试样例",
            "author": "BK 提词器测试",
            "subject": "Synthetic test fixture; not a WPS export",
            "creator": "pdf_generate_fixtures.py",
            "producer": "PyMuPDF fixture generator",
            "creationDate": "D:20260101000000Z",
            "modDate": "D:20260101000000Z",
        }
    )


def save(doc, name, **kwargs):
    stamp(doc)
    doc.subset_fonts()
    path = ROOT / name
    if path.exists():
        path.unlink()
    doc.save(path, garbage=4, deflate=True, no_new_id=True, **kwargs)
    doc.close()


def chinese(page, text, y=76):
    page.insert_text((48, y), text, fontsize=20, fontname="china-s")


def note(annot, content):
    annot.set_info(title="合成样例", content=content)
    annot.update()
    return annot


def unicode_map(doc, font_xref, text):
    # PyMuPDF 1.26.6 emits a five-hex-digit destination for supplementary
    # characters. Author an explicit, standards-valid UTF-16BE ToUnicode map
    # so this fixture actually tests an emoji instead of a truncated codepoint.
    font = fitz.Font(fontfile=str(EMOJI_FONT))
    cmap_xref = int(doc.xref_get_key(font_xref, "ToUnicode")[1].split()[0])
    chars = sorted(set(text))
    mappings = [
        f"<{font.has_glyph(ord(c)):04X}> <{c.encode('utf-16-be').hex().upper()}>"
        for c in chars
    ]
    cmap = (
        "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
        "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
        "/CMapName /FixtureUnicode def\n/CMapType 2 def\n"
        "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n"
        f"{len(mappings)} beginbfchar\n" + "\n".join(mappings) +
        "\nendbfchar\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
    )
    doc.update_stream(cmap_xref, cmap.encode("ascii"))


def main_fixture():
    doc = fitz.open()
    page = doc.new_page(width=640, height=500)
    chinese(page, "知识需要节奏，知识需要停顿。", 76)
    chinese(page, "先停顿，再强调，最后放慢。", 122)
    font_xref = page.insert_font(fontname="fixtureEmoji", fontfile=str(EMOJI_FONT))
    emoji_text = '<A&B> "quote" 😀 after'
    page.insert_text(
        (48, 168), emoji_text, fontsize=20, fontname="fixtureEmoji"
    )
    unicode_map(doc, font_xref, emoji_text)
    page = doc.reload_page(page)
    chinese(page, "页尾：用轻声收尾。", 214)

    knowledge = page.search_for("知识", quads=True)
    assert len(knowledge) == 2
    parent = note(
        page.add_highlight_annot(knowledge[1]), "第二处知识：重读，勿匹配到第一处。"
    )
    parent_xref = parent.xref
    note(page.add_underline_annot(page.search_for("节奏", quads=True)), "节奏：放慢语速。")
    stops = page.search_for("停顿", quads=True)
    assert len(stops) == 2
    note(
        page.add_highlight_annot([stops[1], page.search_for("放慢", quads=True)[0]]),
        "两个不连续词：先停半拍，再放慢。",
    )
    note(
        page.add_highlight_annot(
            [page.search_for("停顿。", quads=True)[0], page.search_for("先停顿", quads=True)[0]]
        ),
        "跨行批注：在这里换气。",
    )
    note(page.add_highlight_annot(page.search_for("<A&B>", quads=True)), "符号必须照读。")
    emoji_quads = page.search_for("😀", quads=True)
    assert len(emoji_quads) == 1
    note(page.add_underline_annot(emoji_quads), "表情位置：微笑后继续。")
    note(page.add_squiggly_annot(page.search_for("轻声", quads=True)), "轻声：尾音下降。")
    note(page.add_strikeout_annot(page.search_for("收尾", quads=True)), "收尾：声音收住。")

    # A nearby icon is NOT a text selection and must never silently anchor.
    note(page.add_text_annot((knowledge[0].rect.x0, 42), "便笺：请人工选词绑定。"), "便笺：请人工选词绑定。")
    note(
        page.add_freetext_annot(
            fitz.Rect(340, 275, 590, 320), "自由文本：这一段要亲切。", fontsize=12
        ),
        "自由文本：这一段要亲切。",
    )
    arrow = note(
        page.add_line_annot(fitz.Point(300, 260), fitz.Point(210, 119)),
        "箭头：位置不等于选词范围。",
    )
    arrow.set_line_ends(0, fitz.PDF_ANNOT_LE_OPEN_ARROW)
    arrow.update()
    reply = note(page.add_text_annot((560, 60), "回复：仍然对应第二处知识。"), "回复：仍然对应第二处知识。")
    reply.set_irt_xref(parent_xref)
    reply.update()
    missing = note(
        page.add_highlight_annot(page.search_for("页尾", quads=True)),
        "缺少选区：必须保留为待定位备注。",
    )
    doc.xref_set_key(missing.xref, "QuadPoints", "null")
    note(
        page.add_highlight_annot(fitz.Rect(450, 350, 560, 380)),
        "空白区域的高亮：不能绑定附近文字。",
    )

    page = doc.new_page(width=640, height=500)
    chinese(page, "旋转页面依然需要重音。", 76)
    # A reply to a markup with empty Contents must inherit the parent's range.
    parent = page.add_highlight_annot(page.search_for("重音", quads=True))
    parent.update()
    parent_xref = parent.xref
    reply = note(page.add_text_annot((540, 90), "旋转页回复：重音抬高。"), "旋转页回复：重音抬高。")
    reply.set_irt_xref(parent_xref)
    reply.update()
    page.set_rotation(90)
    save(doc, "pdf_annotations_synthetic.pdf")


def scan_document():
    source = fitz.open()
    page = source.new_page(width=400, height=220)
    chinese(page, "这是模拟扫描页，没有文字层。", 76)
    pix = page.get_pixmap()
    scan = fitz.open()
    page = scan.new_page(width=400, height=220)
    page.insert_image(page.rect, pixmap=pix)
    note(page.add_text_annot((20, 20), "扫描页的备注也不能静默丢失。"), "扫描页的备注也不能静默丢失。")
    source.close()
    return scan


def other_fixtures():
    doc = fitz.open()
    page = doc.new_page()
    chinese(page, "普通稿件，不含批注。")
    save(doc, "pdf_plain_synthetic.pdf")

    doc = fitz.open()
    doc.new_page()
    save(doc, "pdf_empty_synthetic.pdf")

    scan = scan_document()
    save(scan, "pdf_scanned_synthetic.pdf")

    doc = fitz.open()
    page = doc.new_page()
    chinese(page, "第一页有正文，第二页是扫描件。")
    scan = scan_document()
    doc.insert_pdf(scan, annots=True)
    scan.close()
    save(doc, "pdf_mixed_scanned_synthetic.pdf")

    doc = fitz.open()
    page = doc.new_page()
    chinese(page, "加密样例，需要密码。")
    save(
        doc,
        "pdf_encrypted_synthetic.pdf",
        encryption=fitz.PDF_ENCRYPT_AES_256,
        owner_pw="fixture-owner-only",
        user_pw="fixture-test-only",
    )

    doc = fitz.open()
    page = doc.new_page()
    chinese(page, "此样例禁止复制与提取。")
    save(
        doc,
        "pdf_restricted_synthetic.pdf",
        encryption=fitz.PDF_ENCRYPT_AES_256,
        owner_pw="fixture-owner-only",
        user_pw="",
        permissions=fitz.PDF_PERM_PRINT,
    )
    (ROOT / "pdf_invalid_synthetic.pdf").write_bytes(b"This is deliberately not a PDF document.\n")


if __name__ == "__main__":
    main_fixture()
    other_fixtures()
    print(json.dumps({p.name: p.stat().st_size for p in sorted(ROOT.glob("pdf_*synthetic.pdf"))}, ensure_ascii=False, indent=2))
