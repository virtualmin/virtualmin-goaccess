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

1;
