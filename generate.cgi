#!/usr/bin/perl
# Run an explicitly requested update and report the outcome as it happens.
use strict;
use warnings;
our (%text, %in);
require './virtualmin-goaccess-lib.pl';
&ReadParse();
&require_post();
my $d = &require_domain($in{'dom'}, 'generate');
# Load any web-server plugin before the theme starts building the page.
my $log = &virtual_server::get_website_log($d) || $text{'log_missing'};
&ui_print_unbuffered_header(&virtual_server::domain_in($d), $text{'generate'}, '', undef, 0, 1);
print &text('gen_doing', &ui_tag('tt', &html_escape($d->{'dom'})),
            &ui_tag('tt', &html_escape($log))), &ui_br();
eval { &generate_report($d); };
my $err = $@;
print &ui_tag_start('div', { 'id' => 'goaccess-result' });
if ($err) {
    # The first line names the failure; any parser output follows it.
    my ($first, $rest) = split(/\n/, $err, 2);
    print &text('gen_failed', &ui_tag('tt', &html_escape($first)));
    print &ui_tag('pre', &html_escape($rest)) if defined($rest) && $rest =~ /\S/;
}
else {
    &webmin_log('generate', 'domain', $d->{'dom'}, { 'id' => $d->{'id'} });
    print $text{'gen_done'};
    # The link to the report stands on its own line under the outcome.
    print &ui_tag('div', &ui_tag('a', &html_escape($text{'gen_view'}),
                                 { 'href' => 'view.cgi?dom='.$d->{'id'} }),
                  { 'style' => 'margin-top: 4px' });
}
print &ui_tag_end('div');
&ui_print_footer('view.cgi?dom='.$d->{'id'}, $text{'links_report'});
