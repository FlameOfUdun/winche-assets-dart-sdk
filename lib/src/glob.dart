/// Whether [path] matches [pattern]: `*` is anything within one part, `**` any number of parts
/// (`translations/**`, `**/*.json`, `pages/welcome.html`).
bool matchesPattern(String pattern, String path) => _match(pattern.split('/'), 0, path.split('/'), 0);

bool _match(List<String> p, int i, List<String> s, int j) {
  if (i == p.length) return j == s.length;
  if (p[i] == '**') {
    for (var k = j; k <= s.length; k++) {
      if (_match(p, i + 1, s, k)) return true;
    }
    return false;
  }
  if (j == s.length || !_part(p[i], s[j])) return false;
  return _match(p, i + 1, s, j + 1);
}

bool _part(String pattern, String text) {
  final rx = RegExp('^${pattern.split('*').map(RegExp.escape).join('.*')}\$');
  return rx.hasMatch(text);
}
