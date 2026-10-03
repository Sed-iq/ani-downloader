"""Classic Windows 2000 style front end: search a title (or paste a URL), pick it, download the English dub."""
import queue
import re
import sys
import threading
import time
from pathlib import Path

from PySide6.QtCore import QObject, QSettings, Qt, QUrl, Signal
from PySide6.QtGui import QColor, QDesktopServices, QFont, QPalette, QPixmap
from PySide6.QtWidgets import (
    QAbstractItemView, QApplication, QComboBox, QFileDialog, QFrame, QHBoxLayout, QHeaderView,
    QLabel, QLineEdit, QMainWindow, QMenu, QMessageBox, QProgressBar, QPushButton, QSizePolicy, QSplitter, QStyle,
    QStyledItemDelegate, QStyleOptionProgressBar, QToolButton, QTreeWidget, QTreeWidgetItem,
    QVBoxLayout, QWidget,
)

from . import hls
from .scraper import Anikoto, Result, brief, clean_name, pick_variant

APP = "Anikoto Downloader"
NAME, KIND, DUB, RES = range(4)              # result list columns
EP, TITLE, STATE = range(3)                  # episode list columns
INDEX = Qt.ItemDataRole.UserRole             # EP column: index into anime.episodes
PERCENT = Qt.ItemDataRole.UserRole           # STATE column: 0-100 draws a bar, None plain text
PATH = Qt.ItemDataRole.UserRole + 1          # STATE column: saved file
CHECKED, UNCHECKED = Qt.CheckState.Checked, Qt.CheckState.Unchecked
PROBE_AHEAD, PROBE_WORKERS = 12, 4           # top results whose resolutions are checked unasked


def classic(app):
    """Qt's built-in 'Windows' style with the Windows 2000 3D-face palette and Tahoma 8pt."""
    app.setStyle("Windows")
    R, G = QPalette.ColorRole, QPalette.ColorGroup
    face, gray, white, black = QColor("#d4d0c8"), QColor("#808080"), QColor("#ffffff"), QColor("#000000")
    palette = QPalette()
    for role, color in {
        R.Window: face, R.Button: face, R.Midlight: face, R.AlternateBase: face,
        R.Light: white, R.Mid: QColor("#a0a0a0"), R.Dark: gray, R.Shadow: QColor("#404040"),
        R.Base: white, R.Text: black, R.WindowText: black, R.ButtonText: black, R.BrightText: white,
        R.Highlight: QColor("#0a246a"), R.HighlightedText: white, R.PlaceholderText: gray,
        R.ToolTipBase: QColor("#ffffe1"), R.ToolTipText: black, R.Link: QColor("#0000ff"),
    }.items():
        palette.setColor(role, color)
    for role in (R.Text, R.WindowText, R.ButtonText):
        palette.setColor(G.Disabled, role, gray)
    palette.setColor(G.Disabled, R.Base, face)
    palette.setColor(G.Inactive, R.Highlight, face)       # unfocused selection goes gray, as in Win2k
    palette.setColor(G.Inactive, R.HighlightedText, black)
    app.setPalette(palette)
    font = QFont()
    font.setFamilies(["Tahoma", "MS Shell Dlg 2", "Liberation Sans", "DejaVu Sans"])
    font.setPointSize(8)
    app.setFont(font)


def default_folder():
    for name in ("Videos", "Downloads"):
        if (Path.home() / name).is_dir():
            return str(Path.home() / name)
    return str(Path.home())


def quality_name(height):
    return f"{height}p" if height else "Best"


class RowDelegate(QStyledItemDelegate):
    """A little more air per row than Qt's default, like Win2k list views."""

    def sizeHint(self, option, index):
        size = super().sizeHint(option, index)  # uniform rows take this height for the whole list
        size.setHeight(size.height() + 4)
        return size


class ProgressDelegate(RowDelegate):
    """Draws the status cell as a native (chunked, textless) progress bar plus a percentage."""

    def paint(self, painter, option, index):
        value = index.data(PERCENT)
        if value is None:
            return super().paint(painter, option, index)
        style = option.widget.style()
        style.drawPrimitive(QStyle.PrimitiveElement.PE_PanelItemViewItem, option, painter, option.widget)
        text_width = option.fontMetrics.horizontalAdvance("100%") + 6
        bar = QStyleOptionProgressBar()
        bar.initFrom(option.widget)
        bar.rect = option.rect.adjusted(2, 3, -text_width, -3)
        bar.minimum, bar.maximum, bar.progress = 0, 100, value
        bar.state = QStyle.StateFlag.State_Enabled | QStyle.StateFlag.State_Horizontal
        style.drawControl(QStyle.ControlElement.CE_ProgressBar, bar, painter, option.widget)
        selected = option.state & QStyle.StateFlag.State_Selected
        painter.setPen(option.palette.color(QPalette.ColorRole.HighlightedText if selected else QPalette.ColorRole.Text))
        painter.drawText(option.rect.adjusted(0, 0, -3, 0),
                         Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter, f"{value}%")


class Entry:
    """A search result and what has been learned about it so far."""

    def __init__(self, result):
        self.result = result
        self.anime = None
        self.heights = []
        self.poster = None  # image bytes
        self.state = ""     # "" not loaded, "loading", "done"; claimed under Window.claim


class Events(QObject):
    """Worker threads -> GUI thread (signals are delivered queued).
    `gen` tags work from one search, so late answers to an older search are dropped."""
    searched = Signal(int, object)           # gen, [Result] or error text
    anime = Signal(int, int, object)         # gen, result row, Anime
    heights = Signal(int, int, list)         # gen, result row, heights so far, tallest first
    probed = Signal(int, int, str)           # gen, result row, error ("" when fine)
    poster = Signal(int, int, object)        # gen, result row, image bytes
    row = Signal(int, str, object, str)      # episode row, text, percent or None, tooltip
    saved = Signal(int, str)                 # episode row, file path
    overall = Signal(int, int, float, float)  # job number, jobs, fraction of current, bytes/s
    finished = Signal(int, int, bool)        # saved, failed, stopped


class Window(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle(APP)
        self.setWindowIcon(self.style().standardIcon(QStyle.StandardPixmap.SP_ArrowDown))
        self.site = Anikoto()
        self.gen = 0         # bumped by every search
        self.entries = []    # one per result row
        self.claim = threading.Lock()
        self.anime = None    # the picked result's Anime, once loaded
        self.cancel = None   # threading.Event while a download runs
        self.worker = None
        self.settings = QSettings("kotodl", "kotodl")

        self.query = QLineEdit(placeholderText="Anime name or URL")
        self.query.returnPressed.connect(self.search)
        self.go = QPushButton("Search", default=True)
        self.go.clicked.connect(self.search)

        self.results = QTreeWidget()
        self.results.setHeaderLabels(["Title", "Type", "Dub", "Resolutions"])
        self.results.setRootIsDecorated(False)
        self.results.setUniformRowHeights(True)
        self.results.setItemDelegate(RowDelegate(self.results))
        self.results.currentItemChanged.connect(self.pick)
        self.results.itemClicked.connect(lambda item: self.load(self.results.indexOfTopLevelItem(item)))  # retry
        columns = self.results.header()
        columns.setStretchLastSection(False)
        columns.setSectionResizeMode(NAME, QHeaderView.ResizeMode.Stretch)
        for column, width in ((KIND, 58), (DUB, 50), (RES, 130)):
            columns.setSectionResizeMode(column, QHeaderView.ResizeMode.Fixed)
            columns.resizeSection(column, width)

        self.cover = QLabel()
        self.cover.setFrameShape(QFrame.Shape.Panel)
        self.cover.setFrameShadow(QFrame.Shadow.Sunken)
        self.cover.setFixedSize(48, 66)
        self.cover.setScaledContents(True)
        self.name = QLabel()
        title_font = self.name.font()
        title_font.setBold(True)
        title_font.setPointSize(10)
        self.name.setFont(title_font)
        self.count = QLabel()
        self.header = QWidget()
        info = QVBoxLayout()
        info.addStretch()
        info.addWidget(self.name)
        info.addWidget(self.count)
        info.addStretch()
        header = QHBoxLayout(self.header)
        header.setContentsMargins(0, 0, 0, 0)
        header.addWidget(self.cover)
        header.addLayout(info, 1)
        self.header.setMinimumHeight(self.cover.height())  # no jump when the poster arrives
        self.header.hide()

        self.list = QTreeWidget()
        self.list.setHeaderLabels(["#", "Title", "Status"])
        self.list.setRootIsDecorated(False)
        self.list.setUniformRowHeights(True)
        self.list.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        self.list.setItemDelegateForColumn(STATE, ProgressDelegate(self.list))
        self.list.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.list.customContextMenuRequested.connect(self.menu)
        self.list.itemDoubleClicked.connect(self.play)
        columns = self.list.header()
        columns.setStretchLastSection(False)
        columns.setSectionResizeMode(EP, QHeaderView.ResizeMode.ResizeToContents)
        columns.setSectionResizeMode(TITLE, QHeaderView.ResizeMode.Stretch)
        columns.setSectionResizeMode(STATE, QHeaderView.ResizeMode.Fixed)
        columns.resizeSection(STATE, 110)

        self.quality = QComboBox(toolTip="Resolution")
        self.quality.setMinimumContentsLength(6)
        self.quality.activated.connect(lambda: self.settings.setValue("quality", self.quality.currentData()))
        self.folder = QLineEdit(self.settings.value("folder") or default_folder(), toolTip="Save to")
        self.folder.editingFinished.connect(lambda: self.settings.setValue("folder", self.folder.text()))
        self.browse = QToolButton(text="...", toolTip="Browse")
        self.browse.clicked.connect(self.choose)
        self.start = QPushButton("Download")
        self.start.setMinimumWidth(80)
        self.start.clicked.connect(self.toggle)

        top = QHBoxLayout()
        top.addWidget(self.query, 1)
        top.addWidget(self.go)
        picked = QWidget()
        lower = QVBoxLayout(picked)
        lower.setContentsMargins(0, 0, 0, 0)
        lower.setSpacing(6)
        lower.addWidget(self.header)
        lower.addWidget(self.list, 1)
        self.split = QSplitter(Qt.Orientation.Vertical, childrenCollapsible=False)
        self.split.addWidget(self.results)
        self.split.addWidget(picked)
        self.split.setStretchFactor(1, 1)
        self.split.setSizes([170, 330])
        bottom = QHBoxLayout()
        bottom.addWidget(self.quality)
        bottom.addWidget(self.folder, 1)
        bottom.addWidget(self.browse)
        bottom.addSpacing(12)
        bottom.addWidget(self.start)
        body = QWidget()
        layout = QVBoxLayout(body)
        layout.setContentsMargins(8, 8, 8, 6)
        layout.setSpacing(6)
        layout.addLayout(top)
        layout.addWidget(self.split, 1)
        layout.addLayout(bottom)
        self.setCentralWidget(body)

        self.message = QLabel()
        self.message.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)  # clip, don't widen
        self.bar = QProgressBar(textVisible=False, maximum=1000)
        self.bar.setFixedSize(150, 14)
        self.statusBar().addWidget(self.message, 1)
        self.statusBar().addPermanentWidget(self.bar)

        self.events = Events()
        self.events.searched.connect(self.on_searched)
        self.events.anime.connect(self.on_anime)
        self.events.heights.connect(self.on_heights)
        self.events.probed.connect(self.on_probed)
        self.events.poster.connect(self.on_poster)
        self.events.row.connect(self.on_row)
        self.events.saved.connect(lambda row, path: self.list.topLevelItem(row).setData(STATE, PATH, path))
        self.events.overall.connect(self.on_overall)
        self.events.finished.connect(self.on_finished)

        self.resize(600, 580)
        if self.settings.value("geometry"):
            self.restoreGeometry(self.settings.value("geometry"))
        if self.settings.value("split"):
            self.split.restoreState(self.settings.value("split"))
        clip = QApplication.clipboard().text().strip()
        if re.match(r"(https?://)?(www\.)?anikoto\.\w+/watch/", clip):
            self.query.setText(clip)
        self.lock()
        self.say("Ready")

    # -- state ---------------------------------------------------------------

    def lock(self, searching=False):
        downloading = self.cancel is not None
        idle = not (searching or downloading)
        for widget in (self.query, self.go, self.folder, self.browse):
            widget.setEnabled(idle)
        self.results.setEnabled(not downloading)  # switching titles would swap the episode list mid-run
        self.quality.setEnabled(not downloading and self.quality.count() > 0)
        has_dub = bool(self.anime and any(e.dub for e in self.anime.episodes))
        self.start.setEnabled(downloading or (idle and has_dub))
        self.start.setText("Stop" if downloading else "Download")
        self.bar.setVisible(downloading)

    def say(self, text):
        self.message.setText(text)
        self.message.setToolTip(text)

    def items(self):
        return [self.list.topLevelItem(i) for i in range(self.list.topLevelItemCount())]

    def current(self):
        """Row of the picked result, or -1."""
        item = self.results.currentItem()
        return self.results.indexOfTopLevelItem(item) if item else -1

    # -- search --------------------------------------------------------------

    def search(self):
        text = self.query.text().strip()
        if not text or not self.go.isEnabled():
            return
        self.gen += 1
        self.entries = []
        self.results.clear()
        self.lock(searching=True)
        self.say("Searching…")
        threading.Thread(target=self._search, args=(self.gen, text), daemon=True).start()

    def _search(self, gen, text):
        if "://" in text or "/watch/" in text:  # a pasted watch link opens directly
            self.events.searched.emit(gen, [Result(title=text, url=text)])
            return
        try:
            self.events.searched.emit(gen, self.site.search(text))
        except Exception as e:
            self.events.searched.emit(gen, brief(e))

    def on_searched(self, gen, results):
        if gen != self.gen:
            return
        self.lock()
        if isinstance(results, str):
            self.say("Ready")
            QMessageBox.warning(self, APP, results)
            return
        if not results:
            self.say("No English dub found")
            return
        self.entries = [Entry(r) for r in results]
        self.results.addTopLevelItems([QTreeWidgetItem([r.title, r.kind, r.dub, ""]) for r in results])
        ahead = list(enumerate(self.entries[:PROBE_AHEAD]))
        for row, _ in ahead:
            self.results.topLevelItem(row).setText(RES, "…")
        self.probe(gen, ahead)
        self.results.setCurrentItem(self.results.topLevelItem(0))

    def probe(self, gen, jobs):
        """Check the top results' resolutions in the background, a few at a time."""
        todo = queue.Queue()
        for job in jobs:
            todo.put(job)

        def work():
            while gen == self.gen:
                try:
                    row, entry = todo.get_nowait()
                except queue.Empty:
                    return
                self._load(gen, row, entry)

        for _ in range(PROBE_WORKERS):
            threading.Thread(target=work, daemon=True).start()

    def _load(self, gen, row, entry):
        """Fetch a result's episode list, then its resolutions (every dub server's, combined)."""
        with self.claim:
            if entry.state:
                return
            entry.state = "loading"
        try:
            anime = self.site.anime(entry.result.url)
        except Exception as e:
            entry.state = ""  # picking it again retries
            self.events.probed.emit(gen, row, brief(e))
            return
        self.events.anime.emit(gen, row, anime)
        first = next((e for e in anime.episodes if e.dub), None)
        heights, error = set(), "" if first else "No English dub"
        if first:
            try:
                for stream in self.site.dub_streams(anime, first):  # servers can offer different sets
                    heights |= stream.variants.keys()
                    self.events.heights.emit(gen, row, sorted(heights, reverse=True))
            except Exception as e:
                error = brief(e)  # keep "Best"; each episode is resolved again at download time
        entry.state = "done" if heights or not first else ""  # a failed check retries on click
        self.events.probed.emit(gen, row, error)

    def _poster(self, gen, row, url):
        try:
            self.events.poster.emit(gen, row, self.site.image(url))
        except Exception:
            pass

    def fetch_poster(self, row, entry):
        url = entry.result.poster or (entry.anime and entry.anime.poster)
        if url and entry.poster is None:
            threading.Thread(target=self._poster, args=(self.gen, row, url), daemon=True).start()

    def load(self, row):
        """Load a result unless that's done or underway."""
        if 0 <= row < len(self.entries) and not self.entries[row].state:
            self.results.topLevelItem(row).setText(RES, "…")
            threading.Thread(target=self._load, args=(self.gen, row, self.entries[row]), daemon=True).start()

    def pick(self, item, _previous=None):
        """A result was picked: show what is known now, load the rest."""
        row = self.results.indexOfTopLevelItem(item) if item else -1
        entry = self.entries[row] if 0 <= row < len(self.entries) else None
        self.anime = None
        self.list.clear()
        self.cover.hide()
        self.set_qualities(entry.heights if entry else [])
        self.header.setVisible(entry is not None)
        if entry is None:
            self.lock()
            return
        self.name.setText(entry.result.title)
        self.count.setText("")
        if entry.anime:
            self.show_anime(entry.anime)
        if entry.poster:
            self.show_poster(entry.poster)
        else:
            self.fetch_poster(row, entry)
        self.load(row)
        self.lock()
        self.say("Ready" if entry.state == "done" else "Loading…")

    def show_anime(self, anime):
        self.anime = anime
        self.list.clear()
        rows = []
        for i, ep in enumerate(anime.episodes):
            item = QTreeWidgetItem([ep.num, ep.title or f"Episode {ep.num}", "" if ep.dub else "No dub"])
            item.setData(EP, INDEX, i)
            item.setTextAlignment(EP, Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
            item.setCheckState(EP, CHECKED if ep.dub else UNCHECKED)
            item.setDisabled(not ep.dub)
            rows.append(item)
        self.list.addTopLevelItems(rows)
        self.name.setText(anime.title)
        self.count.setText(f"{len(anime.episodes)} episodes  ·  {sum(e.dub for e in anime.episodes)} English dub")
        self.lock()  # downloading can start before the resolution check finishes

    def show_poster(self, data):
        pixmap = QPixmap()
        if pixmap.loadFromData(data):
            self.cover.setPixmap(pixmap)
            self.cover.show()

    def set_qualities(self, heights):
        self.quality.clear()
        for h in heights or [0]:
            self.quality.addItem(quality_name(h), h)
        found = self.quality.findData(int(self.settings.value("quality", 0)))
        self.quality.setCurrentIndex(max(found, 0))

    def on_anime(self, gen, row, anime):
        if gen != self.gen:
            return
        entry = self.entries[row]
        entry.anime = anime
        item = self.results.topLevelItem(row)
        item.setText(NAME, anime.title)  # a pasted link starts out titled with the URL
        if not item.text(DUB):
            item.setText(DUB, str(sum(e.dub for e in anime.episodes)))
        if row == self.current():
            self.show_anime(anime)
            self.fetch_poster(row, entry)

    def on_heights(self, gen, row, heights):
        if gen != self.gen:
            return
        self.entries[row].heights = heights
        self.results.topLevelItem(row).setText(RES, " · ".join(quality_name(h) for h in heights))
        if row == self.current():
            self.set_qualities(heights)

    def on_probed(self, gen, row, error):
        if gen != self.gen:
            return
        item = self.results.topLevelItem(row)
        if not self.entries[row].heights:
            item.setText(RES, "—")
        item.setToolTip(RES, error)
        if row == self.current() and not self.cancel:
            self.say(error or "Ready")

    def on_poster(self, gen, row, data):
        if gen != self.gen:
            return
        self.entries[row].poster = data
        if row == self.current():
            self.show_poster(data)

    # -- download ------------------------------------------------------------

    def toggle(self):
        if self.cancel:
            self.cancel.set()
            self.start.setEnabled(False)
            self.say("Stopping…")
            return
        jobs = [(row, self.anime.episodes[item.data(EP, INDEX)]) for row, item in enumerate(self.items())
                if item.checkState(EP) == CHECKED and not item.isDisabled()]
        if not jobs:
            self.say("Nothing checked")
            return
        height = self.quality.currentData() or 0
        self.settings.setValue("folder", self.folder.text())
        for row, _ in jobs:
            self.on_row(row, "Queued", None, "")
        self.cancel = threading.Event()
        self.bar.setValue(0)
        self.lock()
        self.worker = threading.Thread(
            target=self._download, args=(self.anime, jobs, height, Path(self.folder.text()), self.cancel), daemon=True)
        self.worker.start()

    def _download(self, anime, jobs, height, folder, cancel):
        events = self.events
        saved = failed = 0
        show = clean_name(anime.title)
        width = max(len(e.num) for e in anime.episodes)  # zero-pad so files sort
        for n, (row, ep) in enumerate(jobs, 1):
            if cancel.is_set():
                break
            name = " - ".join(filter(None, [show, ep.num.zfill(width), clean_name(ep.title)]))
            path = folder / show / f"{name}.mp4"
            if path.exists():
                saved += 1
                events.row.emit(row, "Done", None, str(path))
                events.saved.emit(row, str(path))
                continue
            events.row.emit(row, "Resolving…", None, "")
            events.overall.emit(n, len(jobs), 0.0, 0.0)
            started, shown = 0.0, -1

            def progress(done, total, size):
                nonlocal shown
                percent = done * 100 // total
                if percent != shown:
                    shown = percent
                    events.row.emit(row, f"{percent}%", percent, "")
                    events.overall.emit(n, len(jobs), done / total, size / max(time.monotonic() - started, 0.001))

            try:
                stream = self.site.dub_stream(anime, ep, height)
                path.parent.mkdir(parents=True, exist_ok=True)
                started = time.monotonic()  # speed excludes resolving
                hls.download(pick_variant(stream.variants, height), stream.referer, str(path), progress, cancel)
            except hls.Cancelled:
                events.row.emit(row, "Stopped", None, "")
                break
            except Exception as e:
                failed += 1
                events.row.emit(row, "Failed", None, brief(e))
                continue
            saved += 1
            events.row.emit(row, "Done", None, str(path))
            events.saved.emit(row, str(path))
        events.finished.emit(saved, failed, cancel.is_set())

    def on_row(self, row, text, percent, tip):
        item = self.list.topLevelItem(row)
        item.setText(STATE, text)
        item.setData(STATE, PERCENT, percent)
        item.setToolTip(STATE, tip)
        if percent == 0:  # an episode just started: keep it in view
            self.list.scrollToItem(item)

    def on_overall(self, n, total, fraction, speed):
        self.bar.setValue(int((n - 1 + fraction) / total * 1000))
        rate = f"  ·  {speed / 1e6:.1f} MB/s" if speed else ""
        self.say(f"Episode {n} of {total}{rate}")

    def on_finished(self, saved, failed, stopped):
        self.cancel = self.worker = None
        for item in self.items():
            if item.text(STATE) == "Queued":
                item.setText(STATE, "")
        self.lock()
        summary = f"{saved} saved"
        if failed:
            summary += f",  {failed} failed"
        if stopped:
            summary += ",  stopped"
        self.say(summary)
        QApplication.alert(self)

    # -- list actions --------------------------------------------------------

    def menu(self, pos):
        selected = self.list.selectedItems()
        menu = QMenu(self)
        menu.addAction("Check all", lambda: self.check(self.items(), CHECKED))
        menu.addAction("Uncheck all", lambda: self.check(self.items(), UNCHECKED))
        menu.addSeparator()
        menu.addAction("Check selected", lambda: self.check(selected, CHECKED)).setEnabled(bool(selected))
        menu.addAction("Uncheck selected", lambda: self.check(selected, UNCHECKED)).setEnabled(bool(selected))
        menu.addSeparator()
        menu.addAction("Open folder", self.open_folder)
        menu.exec(self.list.viewport().mapToGlobal(pos))

    def check(self, items, state):
        for item in items:
            if not item.isDisabled():
                item.setCheckState(EP, state)

    def play(self, item):
        if item.data(STATE, PATH):
            QDesktopServices.openUrl(QUrl.fromLocalFile(item.data(STATE, PATH)))

    def open_folder(self):
        folder = Path(self.folder.text())
        if self.anime and (folder / clean_name(self.anime.title)).is_dir():
            folder /= clean_name(self.anime.title)
        QDesktopServices.openUrl(QUrl.fromLocalFile(str(folder)))

    def choose(self):
        path = QFileDialog.getExistingDirectory(self, "Save to", self.folder.text())
        if path:
            self.folder.setText(path)
            self.settings.setValue("folder", path)

    def closeEvent(self, event):
        if self.cancel:
            answer = QMessageBox.question(self, APP, "Stop downloading and exit?")
            if answer != QMessageBox.StandardButton.Yes:
                event.ignore()
                return
            self.cancel.set()
            self.worker.join(5)  # lets the downloader delete its partial file
        self.settings.setValue("geometry", self.saveGeometry())
        self.settings.setValue("split", self.split.saveState())
        event.accept()


def main():
    app = QApplication(sys.argv)
    app.setApplicationName(APP)
    classic(app)
    window = Window()
    window.show()
    return app.exec()
