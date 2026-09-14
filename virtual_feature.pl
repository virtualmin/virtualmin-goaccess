# Virtualmin feature lifecycle, owner access and backup integration.
use strict;
use warnings;
our (%text, %config, $module_name, $module_var_directory);
require 'virtualmin-goaccess-lib.pl';

# feature_name() returns the name in Features and Plugins.
sub feature_name { return $text{'feat_name'}; }

# feature_label([editing]) returns the label in domain creation and editing.
sub feature_label { return $text{'feat_name'}; }

# feature_hlink() selects the domain feature help page.
sub feature_hlink { return 'label'; }

# feature_losing(domain) explains what removing this feature deletes.
sub feature_losing { return $text{'feat_losing'}; }

# feature_disname(domain) names the feature when a domain is suspended.
sub feature_disname { return $text{'feat_name'}; }

# feature_failed(error) reports a failed hook in the ".. failed : reason" form.
sub feature_failed
{
my ($err) = @_;
$err =~ s/\s+\z//;
return &text('feat_failed', &html_escape($err));
}

# feature_check() checks the administrator's GoAccess installation and limits.
sub feature_check { return &check_goaccess(); }

# feature_depends(domain, [old-domain]) requires a website and a Unix owner.
sub feature_depends
{
my ($d) = @_;
return $text{'feat_web'} unless &virtual_server::domain_has_website($d);
return $text{'feat_user'} unless $d->{'unix'} || $d->{'parent'};
return $text{'feat_home'} unless $d->{'dir'};
return undef;
}

# feature_suitable([parent], [alias], [subdomain]) excludes aliases and
# subdomains that share another domain's website.
sub feature_suitable
{
my ($parent, $alias, $subdomain) = @_;
return $alias || $subdomain ? 0 : 1;
}

# feature_clash(domain, [field]) allows coexistence with existing statistics tools.
sub feature_clash { return undef; }

# feature_import(domain-name, username, database) checks for existing settings.
sub feature_import
{
my ($name) = @_;
my $d = &virtual_server::get_domain_by('dom', $name);
return $d && -f (&domain_dir($d).'/settings.json') ? 1 : 0;
}

# feature_setup(domain) creates private settings and the domain's cron job.
sub feature_setup
{
my ($d) = @_;
&$virtual_server::first_print($text{'feat_setup'});
my $ok = eval {
    die $text{'feat_alias'}."\n" if $d->{'alias'} || $d->{'subdom'};
    my $err = &check_goaccess() || &feature_depends($d);
    die "$err\n" if $err;
    &state_lock($d, sub {
        my ($dir) = @_;
        my $s = &load_settings($d);
        # Apply the administrator's defaults only when first enabling reports.
        if (!-f "$dir/settings.json") {
            $s->{'schedule'} = $config{'schedule'} || 'hourly';
            # Standard Apache common logs lack referrer and browser fields.
            if ($d->{'web'}) {
                my ($virt, $vconf) = &virtual_server::get_apache_virtual($d->{'dom'}, $d->{'web_port'});
                my $clog = $virt ? &apache::find_directive('CustomLog', $vconf) : '';
                $s->{'format'} = 'COMMON' if ($clog || '') =~ /\bcommon\s*$/i;
            }
        }
        &save_settings($d, $s);
        &sync_cron($d, $s);
    });
    1;
};
&$virtual_server::second_print($ok ? $virtual_server::text{'setup_done'} : &feature_failed($@));
return $ok ? 1 : 0;
}

# feature_modify(domain, old-domain) preserves ID-based storage on rename/move.
sub feature_modify
{
my ($d, $old) = @_;
&state_lock($d, sub {
    my ($dir) = @_;
    &sync_cron($d, &load_settings($d), -e "$dir/paused");
    # Remove a stale title after a rename; the next update uses the live domain.
    if ($d->{'dom'} ne $old->{'dom'}) {
        unlink("$dir/report.html");
        unlink("$dir/status.json");
    }
});
return 1;
}

# feature_delete(domain) removes only this domain's settings, report and job.
sub feature_delete
{
my ($d) = @_;
&$virtual_server::first_print($text{'feat_delete'});
&state_lock($d, sub {
    my ($dir) = @_;
    # Damaged settings must not prevent removal of the feature or domain.
    &sync_cron($d, undef, 1);
    remove_tree($dir, {safe => 1});
    die "Cannot remove report directory\n" if -e $dir;
});
&$virtual_server::second_print($virtual_server::text{'setup_done'});
return 1;
}

# feature_disable(domain) pauses updates while retaining the last report.
sub feature_disable
{
my ($d) = @_;
&state_lock($d, sub {
    my ($dir) = @_;
    # Suspension must work even if report settings are missing or damaged.
    make_path($dir, { mode => 0700 }) unless -d $dir;
    &write_file_contents("$dir/paused", "1\n");
    &sync_cron($d, undef, 1);
});
return 1;
}

# feature_enable(domain) resumes the saved schedule after a suspension.
sub feature_enable
{
my ($d) = @_;
&state_lock($d, sub {
    my ($dir) = @_;
    unlink("$dir/paused");
    my %enabled = (%$d, disabled => 0);
    &sync_cron(\%enabled, &load_settings($d));
});
return 1;
}

# feature_webmin(domain, domains) grants access to reports owned by this account.
sub feature_webmin
{
my ($d, $domains) = @_;
return () unless grep { $_->{$module_name} } @$domains;
return ([$module_name, {noconfig => 1,
    configure => $config{'noedit'} ? 0 : 1, generate => 1}]);
}

# feature_modules() describes the module available to domain owners.
sub feature_modules
{
return ([$module_name, $text{'index_title'}, undef, 'config_avail', $module_name]);
}

# feature_backup_name() describes the contents in Virtualmin backup options.
sub feature_backup_name { return $text{'feat_backup_name'}; }

# feature_backup(domain, file, options, home-format, differential, as-owner)
# saves settings and the report snapshot. The file is written as the domain
# user, so backups that Virtualmin runs as the owner work too.
sub feature_backup
{
my ($d, $file) = @_;
&$virtual_server::first_print($text{'feat_backup'});
my $ok = eval {
    &state_lock($d, sub {
        my ($dir) = @_;
        my $backup = {version => 1, settings => &load_settings($d)};
        # A newly enabled site may have settings without a generated report.
        if (-f "$dir/report.html") {
            $backup->{'report'} = GoAccess::Report::read_regular("$dir/report.html", 256*1024*1024);
            $backup->{'status'} = &report_status($d);
        }
        # Virtualmin writes the file in a process running as the domain user.
        my $fh = 'BACKUP';
        &virtual_server::open_tempfile_as_domain_user($d, $fh, ">$file", 1, 1)
            or die "Cannot write GoAccess backup: $!\n";
        &print_tempfile($fh, encode_json($backup));
        # With no-error mode, the caller must check for a failed final write.
        &virtual_server::close_tempfile_as_domain_user($d, $fh)
            or die "Cannot finish writing GoAccess backup\n";
    });
    1;
};
&$virtual_server::second_print($ok ? $virtual_server::text{'setup_done'} : &feature_failed($@));
return $ok ? 1 : 0;
}

# feature_restore(domain, file, options, all-options) validates and restores
# settings and the saved report, then rebuilds the update schedule.
sub feature_restore
{
my ($d, $file) = @_;
&$virtual_server::first_print($text{'feat_restore'});
my $ok = eval {
    my $backup = decode_json(GoAccess::Report::read_regular($file, 512*1024*1024));
    die "Unsupported GoAccess backup\n" unless ref($backup) eq 'HASH' && ($backup->{'version'} || 0) == 1;
    my $s = GoAccess::Report::validate($backup->{'settings'});
    die "Invalid report in backup\n" if exists($backup->{'report'}) &&
        (ref($backup->{'report'}) || !defined($backup->{'report'}) ||
         length($backup->{'report'}) > 256*1024*1024 || $backup->{'report'} !~ /<!doctype html|<html/i);
    my $status = $backup->{'status'} || {};
    die "Invalid report summary in backup\n" unless ref($status) eq 'HASH' && length(encode_json($status)) <= 65536;
    &state_lock($d, sub {
        my ($dir) = @_;
        &save_settings($d, $s);
        # Restore the matching snapshot, or discard one absent from the backup.
        if (exists($backup->{'report'})) {
            &write_file_contents("$dir/report.html", $backup->{'report'});
            &write_file_contents("$dir/status.json", encode_json($status));
        }
        else {
            # A settings-only backup must not retain unrelated old statistics.
            unlink("$dir/report.html");
            unlink("$dir/status.json");
        }
        &sync_cron($d, $s, -e "$dir/paused");
    });
    1;
};
&$virtual_server::second_print($ok ? $virtual_server::text{'setup_done'} : &feature_failed($@));
return $ok ? 1 : 0;
}

# feature_validate(domain) checks the executable, domain requirements,
# settings and scheduled update job.
sub feature_validate
{
my ($d) = @_;
my $error = &check_goaccess() || &feature_depends($d);
return $error if $error;
my $dir = &domain_dir($d);
return $text{'feat_missing'} unless -f "$dir/settings.json";
my $s = eval { &load_settings($d) };
return &html_escape($@) if $@;
# Only an active scheduled report needs a cron job to pass validation.
if ($s->{'schedule'} ne 'manual' && !$d->{'disabled'} && !-e "$dir/paused") {
    my @jobs = &find_cron_jobs($d);
    return $text{'feat_cron'} unless @jobs == 1 && $jobs[0]->{'active'};
}
return undef;
}

1;
