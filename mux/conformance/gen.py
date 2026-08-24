#!/usr/bin/env python3
"""Generate VT conformance corpora: byte streams replayed into both
the engine and tmux; run.sh diffs the resulting screens."""
import pathlib

E = "\x1b"
CSI = E + "["

def w(name, body):
    pathlib.Path(f"corpus/{name}.vt").write_bytes(
        (CSI + "2J" + CSI + "H" + body).encode())

pathlib.Path("corpus").mkdir(exist_ok=True)

# 1. autowrap: exactly-80 line, char past margin, wide char straddle
w("wrap",
  "A" * 80 +                       # fills row 1 exactly (pending wrap)
  "B" +                            # wraps to row 2
  CSI + "4;1H" + "C" * 79 + "永" + # wide char at col 80: must push to next row
  CSI + "7;1H" + CSI + "?7l" + "D" * 90 + CSI + "?7h" +  # autowrap off: pin at margin
  CSI + "9;1HEND")

# 2. wide + combining + emoji
w("wide",
  "漢字テスト\r\n" +
  "é combining acute\r\n" +   # e + U+0301
  "🎉 emoji basic\r\n" +
  "👩‍👩‍👧 zwj family\r\n" +
  "ｱｲｳ halfwidth kana\r\n" +
  "END")

# 3. scroll region: DECSTBM + IND/RI + IL/DL inside region
w("scroll",
  "top-line\r\n" + "\r\n".join(f"row{i}" for i in range(2, 11)) +
  CSI + "3;8r" +                   # region rows 3..8
  CSI + "8;1H" + "\n\n" +          # two scrolls inside region
  CSI + "3;1H" + E + "M" +         # RI at top of region: scroll down
  CSI + "5;1H" + CSI + "2L" + "inserted" +   # IL
  CSI + "7;1H" + CSI + "1M" +      # DL
  CSI + "r" + CSI + "12;1HEND")

# 4. cursor choreography
w("cursor",
  CSI + "5;10H*five-ten*" +
  CSI + "2A" + "up2" + CSI + "3B" + "down3" + CSI + "10D" + "left10" +
  CSI + "20G" + "col20" + CSI + "8d" + "row8" +
  E + "7" + CSI + "10;40Hsaved-here" + E + "8" + "@restored" +
  CSI + "12;1HEND")

# 5. edit ops: ICH/DCH/ECH, IRM, EL/ED
w("edit",
  "abcdefghij\r" + CSI + "5G" + CSI + "3@" + "XYZ" +      # insert 3 at col5
  CSI + "2;1Habcdefghij\r" + CSI + "3G" + CSI + "2P" +     # delete 2
  CSI + "3;1Habcdefghij\r" + CSI + "4G" + CSI + "3X" +     # erase 3
  CSI + "4;1H" + CSI + "4h" + "ins" + CSI + "4l" +          # IRM briefly
  CSI + "5;1H0123456789" + CSI + "5G" + CSI + "K" +         # EL to end
  CSI + "6;1H0123456789" + CSI + "5G" + CSI + "1K" +        # EL to start
  CSI + "8;1HEND")

# 6. tabs: default stops, HTS, TBC
w("tabs",
  "a\tb\tc\td\r\n" +
  CSI + "2;5H" + E + "H" + "\r" + "x\tafter-hts\r\n" +
  CSI + "3g" + CSI + "4;1H" + "y\tz-no-stops\r\n" +
  "END")

# 7. alt screen round trip
w("altscreen",
  "primary-content\r\n" +
  CSI + "?1049h" + CSI + "2J" + CSI + "H" + "alt-content" +
  CSI + "?1049l" + CSI + "3;1H" + "back-on-primary\r\n" + "END")

# 8. origin mode: CUP is region-relative
w("origin",
  CSI + "5;20r" + CSI + "?6h" + CSI + "1;1H" + "origin-top" +
  CSI + "?6l" + CSI + "r" + CSI + "1;1H" + "absolute-top" +
  CSI + "10;1HEND")

# 9. SGR through text (styles exercise the parser; text is compared)
w("sgr",
  CSI + "1mBold" + CSI + "0m " + CSI + "3mItal" + CSI + "0m " +
  CSI + "4mUnder" + CSI + "0m " + CSI + "7mInv" + CSI + "0m\r\n" +
  "".join(CSI + f"3{i}mc{i}" for i in range(8)) + CSI + "0m\r\n" +
  "".join(CSI + f"38;5;{i}mp{i}" for i in (16, 82, 196, 226, 244)) + CSI + "0m\r\n" +
  CSI + "38;2;200;100;50mtruecolor" + CSI + "0m\r\n" + "END")

# 10. scrollback push: 60 lines through a 24-row screen
w("scrollpush",
  "\r\n".join(f"line-{i:03d}" for i in range(60)) + "\r\nEND")

print("corpora:", len(list(pathlib.Path('corpus').glob('*.vt'))))
