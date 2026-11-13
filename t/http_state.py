"""HTTP regressions for a disposable ga-test-* domain with manual updates.

Call check_log_states(), check_report_controls() or check_geoip_setup() with an
authenticated callback. The callback accepts a CGI path and returns body,
headers and HTTP status. check_geoip_setup() also passes a form to POST.
"""
from html.parser import HTMLParser
from html import unescape
import json
import os
from pathlib import Path
import re
import shlex
from urllib.parse import parse_qs, urljoin, urlsplit


def check_geoip_setup(request, domain_id, databases, state_dir):
    """check_geoip_setup(request, domain_id, databases, state_dir).

    Test GeoIP saves and visible warnings.
    request(path, form=None) sends GET or a form POST as the administrator.
    databases holds MMDB fixtures; state_dir holds this domain's saved report.
    Run only on a disposable VM with the fixture's cron updates paused.
    """
    config_path = Path('/etc/webmin/virtualmin-goaccess/config')
    saved_config = config_path.read_bytes()
    status_path = Path(state_dir) / 'status.json'
    saved_status = status_path.read_bytes()
    config = dict(line.split('=', 1) for line in saved_config.decode().splitlines() if '=' in line)
    # Avoid racing scheduled updates while replacing fixture state.
    assert domain_id.isdigit() and Path(state_dir).name == domain_id
    assert json.loads((Path(state_dir) / 'settings.json').read_text())['schedule'] == 'manual'
    valid = dict(config, module='virtualmin-goaccess', save='1',
                 geoip_city=str(Path(databases) / 'GeoIP2-City-Test.mmdb'),
                 geoip_asn=str(Path(databases) / 'GeoLite2-ASN-Test.mmdb'))
    try:
        # Save working database paths before checking rejected changes.
        body, _, code = request('/config.cgi?module=virtualmin-goaccess')
        assert code == 200 and b'name="geoip_city"' in body, 'Standard module fields must render'
        body, _, code = request('/config_save.cgi', valid)
        assert code in (200, 302) and valid['geoip_city'].encode() in config_path.read_bytes(), \
            'Valid GeoIP settings must be saved'
        accepted = config_path.read_bytes()
        # Supply corrupt data and a parser without GeoIP support.
        broken = Path(databases) / 'broken.mmdb'
        broken.write_text('not a MaxMind database')
        broken.chmod(0o644)
        unsupported = Path(databases) / 'no-geoip'
        unsupported.write_text("#!/bin/sh\necho 'GoAccess - 1.9.3. --enable-utf8'\n")
        unsupported.chmod(0o755)
        cases = [({'geoip_city': str(Path(databases) / 'missing.mmdb')}, b'not a readable file'),
                 ({'geoip_city': str(broken)}, b'Unable to open GeoIP2 database'),
                 ({'goaccess': str(unsupported)}, b'GoAccess must be built with GeoIP2 support')]
        # Failed validation must preserve the last accepted settings.
        for change, expected in cases:
            body, _, code = request('/config_save.cgi', dict(valid, **change))
            assert expected in body, 'Invalid database must have a visible save error: ' + str(code)
            assert config_path.read_bytes() == accepted, 'Rejected settings must not replace working settings'

        # Viewing a report must not rerun the parser after a database breaks.
        calls = Path(databases) / 'parser-calls'
        calls.write_bytes(b'')
        calls.chmod(0o666)
        probe = Path(databases) / 'goaccess-probe'
        probe.write_text('#!/bin/sh\nprintf x >> ' + shlex.quote(str(calls)) +
                         '\nexec ' + shlex.quote(config['goaccess']) + ' "$@"\n')
        probe.chmod(0o755)
        broken_config = dict(valid, geoip_city=str(broken), goaccess=str(probe))
        config_path.write_text(''.join(key + '=' + value + '\n' for key, value in broken_config.items()
                                      if key not in ('module', 'save')))
        body, _, code = request('/virtualmin-goaccess/view.cgi?dom=' + domain_id)
        assert code == 200 and b'GeoIP setup check failed' not in body
        assert b'id="goaccess-frame"' in body, 'A broken database must leave report viewing available'
        body, _, code = request('/virtualmin-goaccess/')
        assert code == 200 and b'GeoIP setup check failed' not in body
        assert calls.read_bytes() == b'', 'Viewing reports must not invoke GoAccess'
        config_path.write_bytes(accepted)

        # Warnings must be escaped and leave the report available.
        status = json.loads(saved_status)
        warning = 'Local referrers are hidden for only 32 of 40 website names. <test>'
        status['warnings'] = [warning]
        status_path.write_text(json.dumps(status))
        body, _, code = request('/virtualmin-goaccess/view.cgi?dom=' + domain_id)
        assert code == 200 and b'32 of 40' in body and b'&lt;test&gt;' in body
        assert b'id="goaccess-frame"' in body
        body, _, code = request('/virtualmin-goaccess/')
        assert code == 200 and b'Available with warnings' in body
        print('HTTP GeoIP saves, report viewing and warnings passed', flush=True)
    finally:
        # Restore both files even if an HTTP assertion fails.
        config_path.write_bytes(saved_config)
        status_path.write_bytes(saved_status)


def check_report_controls(request, domain_id, admin=False):
    """check_report_controls(request, domain_id, [admin]) tests report controls.

    request is an authenticated HTTP callback. admin defaults to False for owners.
    """
    view = '/virtualmin-goaccess/view.cgi?dom=' + domain_id
    body, _, code = request('/virtualmin-goaccess/edit.cgi?dom=' + domain_id)
    assert code == 200 and b'name="hide_local_referrers"' in body
    body, _, code = request(view)
    assert code == 200
    links = [unescape(link) for link in re.findall(r'href="([^"]+)"', body.decode())]
    # Owner and administrator log links use different permission checks.
    log_link = next(link for link in links if 'logviewer/view_log.cgi?' in link)
    query = parse_qs(urlsplit(log_link).query)
    assert ('file' if admin else 'extra') in query
    body, _, code = request(urljoin(view, log_link))
    assert code == 200 and b'name="filter"' in body, 'Access-log search must open'
    assert b'/index.html' in body, 'Access-log search must show this fixture log'
    if admin:
        # Only administrators can set shared database paths.
        body, _, code = request('/config.cgi?virtualmin-goaccess')
        assert code == 200
        for field in ('geoip_country', 'geoip_city', 'geoip_asn'):
            assert ('name="' + field + '"').encode() in body
    print('HTTP report controls passed for ' + ('administrator' if admin else 'domain owner'), flush=True)


class Forms(HTMLParser):
    """Collect form actions without depending on the active Webmin theme."""

    def __init__(self):
        """__init__() starts with no form actions."""
        super().__init__()
        self.actions = []

    def handle_starttag(self, tag, attrs):
        """handle_starttag(tag, attrs) records form action URLs."""
        # Other HTML elements do not declare form submissions.
        if tag == 'form':
            self.actions.append(dict(attrs).get('action', ''))


def check_log_states(request, domain_id, log_path, state_dir, max_logs):
    """check_log_states(request, domain_id, log_path, state_dir, max_logs).

    Test failed, empty and paused reports through the authenticated request
    callback. Use this fixture's access log, report directory and log limit.
    Restore changed files afterward.
    """
    log_path, state_dir = Path(log_path), Path(state_dir)
    fixture = log_path.parent.parent.name
    assert os.geteuid() == 0 and Path('/etc/webmin/virtual-server').is_dir()
    assert re.fullmatch(r'ga-test-[a-f0-9]+', fixture)
    assert domain_id.isdigit() and state_dir.name == domain_id
    # Save fixture files before simulating broken and empty logs.
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
        """check(expected, action) checks the message and update form."""
        body, _, code = request('/virtualmin-goaccess/view.cgi?dom=' + domain_id)
        assert code == 200 and expected.encode() in body, expected
        forms = Forms()
        forms.feed(body.decode())
        assert any(url.endswith('generate.cgi') for url in forms.actions) == action
        if expected != 'No traffic yet':
            # Failures and suspension must not be described as empty traffic.
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
            # Restore the original log if the non-file check was interrupted.
            if log_path.is_dir():
                # Remove the temporary directory before moving the log back.
                log_path.rmdir()
            hidden_log.rename(log_path)
        log_path.write_bytes(saved_log)
        settings_path.write_bytes(saved_settings)
        hidden_report.rename(report)
