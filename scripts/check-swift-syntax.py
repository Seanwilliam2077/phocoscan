"""Optional tree-sitter syntax validation; never a substitute for Xcode type checking.

python -m pip install --target work/python-validation tree-sitter==0.25.2 tree-sitter-swift==0.7.4
python scripts/check-swift-syntax.py
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / "work" / "python-validation"))
try:
    from tree_sitter import Language, Parser
    import tree_sitter_swift
except ImportError:
    raise SystemExit("Optional syntax parser missing; see this script's docstring. iOS builds still require Xcode.")
parser = Parser(Language(tree_sitter_swift.language()))
files = sorted((root / "ios").glob("PocketWorld*/**/*.swift"))
errors = []
for file in files:
    source = file.read_bytes()
    tree = parser.parse(source)
    stack = [tree.root_node]
    while stack:
        node = stack.pop()
        if node.type == "ERROR" or node.is_missing:
            errors.append(f"{file.relative_to(root)}:{node.start_point.row + 1}:{node.start_point.column + 1}: {node.type}: {source[node.start_byte:node.end_byte][:100]!r}")
        stack.extend(reversed(node.children))
if errors:
    print("\n".join(errors))
    raise SystemExit(1)
print(f"Swift grammar parse passed: {len(files)} files. Does not check SDK APIs, types, actor isolation, linking or signing.")
