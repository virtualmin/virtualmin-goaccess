"""HTTP regressions for a disposable ga-test-* domain with manual updates.

Call check_log_states() on the VM with an authenticated request callback.
The callback accepts a CGI path and returns body, headers and HTTP status.
"""
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re


class Forms(HTMLParser):
    """Collect form actions without depending on the active Webmin theme."""

    def __init__(self):
        """Start with no form actions."""
        super().__init__()
        self.actions = []

    def handle_starttag(self, tag, attrs):
        """Record each form's action URL."""
        if tag == 'form':
            self.actions.append(dict(attrs).get('action', ''))


def check_log_states(request, domain_id, log_path, state_dir, max_logs):
    """Check failed, empty and paused log states, then restore fixture files."""
    log_path, state_dir = Path(log_path), Path(state_dir)
    fixture = log_path.parent.parent.name
    assert os.geteuid() == 0 and Path('/etc/webmin/virtual-server').is_dir()
    assert re.fullmatch(r'ga-test-[a-f0-9]+', fixture)
    assert domain_id.isdigit() and state_dir.name == domain_id
    settings_path = state_dir / 'settings.json'
    saved_settings = settings_path.read_bytes()
    settings = json.loads(saved_settings)
    assert settings['schedule'] == 'manual', 'Pause fixture cron updates first'
    log_path = log_path.resolve(strict=True)
    saved_log = log_path.read_bytes()
    report = state_dir / 'report.html'
    hidden_report = state_dir / 'report.http-test.html'
    hidden_log = log_path.with_name(log_path.name + '.http-test')
    paused = state_dir / 'paused'
    assert not hidden_report.exists() and not hidden_log.exists() and not paused.exists()
    rotations = []

    def check(expected, action):
        """Check the visible state and whether report generation is offered."""
        body, _, code = request('/virtualmin-goaccess/view.cgi?dom=' + domain_id)
        assert code == 200 and expected.encode() in body, expected
        forms = Forms()
        forms.feed(body.decode())
        assert any(url.endswith('generate.cgi') for url in forms.actions) == action
        if expected != 'No traffic yet':
            assert b'No traffic yet' not in body

    report.rename(hidden_report)
    try:
        # Exceed the configured limit using only this fixture's log rotations.
        for number in range(10000, 10000 + max_logs):
            rotation = log_path.with_name(log_path.name + '.' + str(number))
            with rotation.open('xb'):
                pass
            rotations.append(rotation)
        check('Too many rotated logs', True)
        for rotation in rotations:
            rotation.unlink()
        rotations.clear()

        # A non-file log must show an error, with a retry still available.
        log_path.rename(hidden_log)
        log_path.mkdir()
        check('Access log is not a regular file', True)
        log_path.rmdir()
        hidden_log.rename(log_path)

        # Genuine empty logs hide generation; suspension takes precedence.
        settings['rotated'] = 0
        settings_path.write_text(json.dumps(settings))
        log_path.write_bytes(b'')
        check('No traffic yet', False)
        paused.touch(mode=0o600)
        check('Reporting is paused', False)
        print('HTTP log-state checks passed: discovery error, invalid log, empty log and suspension', flush=True)
    finally:
        # Restore all fixture content even when a page assertion fails.
        paused.unlink(missing_ok=True)
        for rotation in rotations:
            rotation.unlink(missing_ok=True)
        if hidden_log.exists():
            if log_path.is_dir():
                log_path.rmdir()
            hidden_log.rename(log_path)
        log_path.write_bytes(saved_log)
        settings_path.write_bytes(saved_settings)
        hidden_report.rename(report)
