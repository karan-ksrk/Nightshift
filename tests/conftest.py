import sys
from pathlib import Path

# main.py / db.py / selector.py live at repo root, not in a package. Put the
# root on sys.path so `import db`, `import selector`, `import main` work when
# pytest is run from anywhere.
sys.path.insert(0, str(Path(__file__).parent.parent))
