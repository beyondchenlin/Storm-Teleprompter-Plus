"""Original RC-only PDF comment fixture; no Office application export.

Development-only dependency: PyMuPDF. This intentionally omits Contents and
uses XHTML paragraphs / line breaks in RC so the native importer exercises
its rich-text fallback, not just the pure conversion helper.
"""

from pathlib import Path

import fitz


def main():
    doc = fitz.open()
    page = doc.new_page(width=500, height=220)
    page.insert_text((48, 76), "讲知识需要节奏。", fontsize=20, fontname="china-s")
    annot = page.add_highlight_annot(page.search_for("节奏", quads=True))
    annot.set_info(title="合成富文本测试")
    annot.update()
    rich = (
        '<body xmlns="http://www.w3.org/1999/xhtml">'
        '<p><span>放慢</span><span>语速</span></p>'
        '<p>停一秒<br/>再继续</p></body>'
    )
    doc.xref_set_key(annot.xref, "Contents", "null")
    doc.xref_set_key(annot.xref, "RC", fitz.get_pdf_str(rich))
    doc.set_metadata({
        "title": "合成富文本批注测试",
        "author": "BK 提词器测试",
        "subject": "Synthetic RC-only annotation fixture; not a WPS export",
        "creationDate": "D:20260101000000Z",
        "modDate": "D:20260101000000Z",
    })
    target = Path(__file__).with_name("pdf_rich_comment_synthetic.pdf")
    doc.save(target, garbage=4, deflate=True, no_new_id=True)
    doc.close()


if __name__ == "__main__":
    main()
