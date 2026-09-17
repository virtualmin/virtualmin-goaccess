#!/usr/bin/perl
# Validate and save settings without allowing users to change paths or commands.
use strict;
use warnings;
our (%text, %in);
require './virtualmin-goaccess-lib.pl';
&ReadParse();
&require_post();
my $d = &require_domain($in{'dom'}, 'configure');
eval {
    my $s = &settings_input(\%in);
    &state_lock($d, sub {
        my ($dir) = @_;
        &sync_cron($d, $s, -e "$dir/paused");
        &save_settings($d, $s);
    });
};
&error(&html_escape($@)) if $@;
&webmin_log('save', 'domain', $d->{'dom'}, { 'id' => $d->{'id'} });
&redirect('view.cgi?dom='.$d->{'id'});
