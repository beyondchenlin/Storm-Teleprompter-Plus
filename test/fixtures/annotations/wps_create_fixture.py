"""Create an actual WPS-saved comment fixture on an isolated Windows desktop.

Requires the installed office application, pywin32, and optionally pywinauto.
This script creates a new synthetic document; it never opens an existing file.
Run with an empty --output-dir. The application remains open for inspection.
"""

import argparse
import json
from pathlib import Path

import pythoncom
import win32com.client


def utf16_length(text):
    return len(text.encode("utf-16-le")) // 2


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--screenshot", action="store_true")
    args = parser.parse_args()
    output = Path(args.output_dir)
    output.mkdir(parents=True, exist_ok=True)
    document_path = output / "wps_actual_annotations.docx"
    metadata_path = output / "wps_actual_annotations.expected.json"
    if document_path.exists() or metadata_path.exists():
        raise FileExistsError("Use an empty output directory; existing fixtures are protected")

    pythoncom.CoInitialize()
    app = None
    failures = []
    prog_id = None
    for candidate in ("kwps.Application", "WPS.Application"):
        try:
            app = win32com.client.DispatchEx(candidate)
            prog_id = candidate
            break
        except pythoncom.com_error as error:
            failures.append({"progId": candidate, "hresult": error.hresult})
    if app is None:
        raise RuntimeError(json.dumps({"noWpsAutomation": failures}))

    app.Visible = True
    document = app.Documents.Add()
    script = (
        "学习的关键，不是记住更多。\r"
        "而是能够真正用得出来。\r"
        "接下来，我们看一个简单的例子。\r"
        "重复词：理解，再理解。\r"
        "先想清楚。\r"
        "再讲明白。\r"
    )
    document.Content.Text = script
    document.Content.Font.Size = 20

    def selection(quote, occurrence=0):
        cursor = -1
        for _ in range(occurrence + 1):
            cursor = script.index(quote, cursor + 1)
        return cursor, cursor + len(quote)

    requested = [
        (*selection("不"), "重读"),
        (*selection("用得出来"), "放慢语速\r把意思讲清楚"),
        (*selection("理解", 1), "只标注第二处理解"),
        (*selection("先想清楚。\r再讲明白。"), "跨段提示\r先想，再说"),
    ]
    metadata = {
        "applicationProgId": prog_id,
        "applicationVersion": str(app.Version),
        "syntheticFixture": True,
        "creationMethod": "Office COM Comments.Add then native SaveAs",
        "requestedStoryText": script,
        "comments": [],
    }
    comments = []
    # WPS includes inserted comment-reference markers in later COM positions.
    # Add from the end of the story so earlier requested positions stay exact.
    for index, (start, end, text) in reversed(list(enumerate(requested))):
        begin = utf16_length(script[:start])
        finish = utf16_length(script[:end])
        selected = document.Range(begin, finish)
        if str(selected.Text) != script[start:end]:
            raise RuntimeError("The office selection differs from the requested quote")
        comment = document.Comments.Add(selected, text)
        comment.Author = "示例教练"
        comments.append((index, start, end, text, comment))

    for index, start, end, text, comment in sorted(comments):
        if str(comment.Scope.Text) != script[start:end]:
            raise RuntimeError("The saved comment scope differs from the requested quote")
        record = {
            "ordinal": index + 1,
            "requestedQuote": script[start:end],
            "requestedNote": text.replace("\r", "\n"),
            "officeStart": int(comment.Scope.Start),
            "officeEnd": int(comment.Scope.End),
            "officeQuote": str(comment.Scope.Text),
            "officeNote": str(comment.Range.Text),
            "rawStart": utf16_length(script[:start].replace("\r", "")),
            "rawEnd": utf16_length(script[:end].replace("\r", "")),
            "rawQuote": script[start:end].replace("\r", ""),
        }
        metadata["comments"].append(record)

    try:
        document.SaveAs2(str(document_path), 12)
    except (AttributeError, pythoncom.com_error):
        document.SaveAs(str(document_path), 12)
    metadata["actualStoryText"] = str(document.Content.Text)
    metadata["savedCommentCount"] = int(document.Comments.Count)
    metadata["savedFileBytes"] = document_path.stat().st_size
    metadata_path.write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(metadata, ensure_ascii=True), flush=True)

    if args.screenshot:
        from pywinauto import Desktop

        matches = [
            window
            for window in Desktop(backend="win32").windows()
            if document_path.stem in window.window_text()
        ]
        if len(matches) != 1:
            raise RuntimeError("Could not uniquely identify the synthetic document window")
        window = matches[0]
        window.restore()
        window.set_focus()
        window.capture_as_image().save(output / "wps_actual_annotations.window.png")


if __name__ == "__main__":
    main()
