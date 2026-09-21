#!/usr/bin/perl
# List reports visible to the current Virtualmin user.
use strict;
use warnings;
our %text;
require './virtualmin-goaccess-lib.pl';

&ui_print_header(undef, $text{'index_title'}, '', undef, 1, 1);
print &ui_page_start({ 'id' => 'goaccess-index', 'class' => 'goaccess' });
my $error = &check_goaccess();
print &ui_alert(&html_escape($error), 'danger') if $error;
my @domains = sort { $a->{'dom'} cmp $b->{'dom'} }
    grep { &allowed_domain($_->{'id'}) } &virtual_server::list_domains();
if (@domains) {
    print &ui_columns_start([$text{'domain'}, $text{'schedule'},
        $text{'updated'}, $text{'requests'}, $text{'status'}], '100%');
    foreach my $d (@domains) {
        my ($settings, $status, $err);
        eval { $settings = &load_settings($d); $status = &report_status($d); };
        $err = $@;
        $status ||= {};
        my $summary = ref($status->{'general'}) eq 'HASH' ? $status->{'general'} : {};
        # Unreadable state counts as a failure the administrator should see.
        my ($label, $kind) = $err || $status->{'error'} ? ('status_error', 'danger') :
            $d->{'disabled'} ? ('status_paused', 'neutral') :
            $status->{'generated'} ? ('status_ready', 'success') : ('status_pending', 'info');
        print &ui_columns_row([
            &ui_tag('a', &html_escape($d->{'dom'}), { 'href' => 'view.cgi?dom='.$d->{'id'} }),
            &html_escape($settings ? $text{'schedule_'.$settings->{'schedule'}} : '-'),
            $status->{'generated'} && $status->{'generated'} =~ /\A\d+\z/
                ? &make_date($status->{'generated'}) : &html_escape($text{'never'}),
            &html_escape($summary->{'valid_requests'} // '-'),
            &ui_badge($text{$label}, $kind, { 'small' => 1, 'dot' => 1 })]);
    }
    print &ui_columns_end();
}
else {
    print &ui_empty_state({ 'icon' => 'globe', 'title' => $text{'index_empty_title'},
                            'desc' => $text{'index_empty'} });
}
print &ui_page_end();
&ui_print_footer('/', $text{'index'});
