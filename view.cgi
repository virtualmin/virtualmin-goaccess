#!/usr/bin/perl
# Show the current dashboard or a first-report screen inside Virtualmin.
use strict;
use warnings;
our (%text, %in);
require './virtualmin-goaccess-lib.pl';
require './report-ui.pl';
&ReadParse();
my $d = &require_domain($in{'dom'});
my ($status, $settings);
eval { $status = &report_status($d); $settings = &load_settings($d); };
&error(&html_escape($@)) if $@;
my $dir = &domain_dir($d);
# Show an empty state for reports built from empty logs. Check the current
# logs below to decide whether a first report can now be generated.
my $empty = ref($status->{'input'}) eq 'HASH' && !$status->{'input'}->{'bytes'};
my $exists = -f "$dir/report.html" && !$empty;
my $paused = $d->{'disabled'} || -e "$dir/paused";
my $can_generate = &allowed_domain($d->{'id'}, 'generate') && !$paused;
my $can_configure = &allowed_domain($d->{'id'}, 'configure');
&ui_print_header(&virtual_server::domain_in($d), $text{'links_report'}, '', undef, 0, 1);
print &ui_page_start({ 'id' => 'goaccess-view', 'class' => 'goaccess' });
# Keep summary text at the page's font size, align its actions with the title
# and let them wrap on narrow screens. Show a spinner while the frame loads.
print &ui_tag('style',
    '.goaccess .ui_card_desc, .goaccess .ui_card_foot { font-size: inherit; } '.
    '.goaccess .ui_card_head { align-items: center; padding-right: 7px; } '.
    '.goaccess .ui_card_actions { margin-bottom: 0; flex-wrap: wrap; max-width: 100%; } '.
    '.goaccess .goaccess-frame-box { position: relative; } '.
    '.goaccess .goaccess-frame-loading { position: absolute; inset: 0; display: flex; '.
    'justify-content: center; align-items: flex-start; padding-top: 24px; pointer-events: none; } '.
    '.goaccess .goaccess-frame-loading .ui_progress_ring_bar { color: var(--ui-accent); } '.
    '.goaccess .btn .fa-cog { position: relative; top: -2px; }');

# Preserve a usable last report and reveal technical failure details on demand.
if ($status->{'error'}) {
    print &report_error($text{$exists ? 'report_failed' : 'report_first_failed'},
                        $status->{'error'}, $exists ? 'warning' : 'danger',
                        $status->{'attempted'});
}

# Group report actions, the last update time and the schedule in one card.
my $schedule = $text{$paused ? 'schedule_paused' : 'auto_'.$settings->{'schedule'}};
my %card = ( 'title' => $text{'summary_title'}, 'desc' => $schedule );
if ($exists) {
    my @actions;
    push(@actions, &report_generate_form($d)) if $can_generate;
    push(@actions, &ui_link_icon('report.cgi?dom='.$d->{'id'}.'&amp;download=1',
                                 &html_escape($text{'download'}), 'download'));
    push(@actions, &report_settings_link($d, 'cog')) if $can_configure;
    $card{'actions'} = \@actions;
    # The date formatter returns trusted theme markup for a validated timestamp.
    $card{'desc_html'} = &html_escape($text{'updated'}.': ').&make_date($status->{'generated'})
        if ($status->{'generated'} || '') =~ /\A\d+\z/;
    # Keep update details above the dashboard's traffic statistics.
    print &ui_card({ %card, 'body' => '',
        'footer' => &html_escape($schedule).' &middot; '.
            &html_escape(&text('summary_format', &report_format_label($d, $settings))) });
    # The card supplies the border; the frame's page blends into its surface.
    print &ui_card({ 'flush' => 1, 'body' => &report_frame($d) });
}
else {
    # Choose a message based on suspension, log data and update permissions.
    my $data = eval { $paused ? 0 : &log_data($d, $settings) };
    my $log_error = $@;
    my ($icon, $heading, $description) =
        $paused ? ('stop', 'empty_paused_title', 'empty_paused') :
        !$data ? ('inbox', 'nolog_title', 'nolog_description') :
        ('globe', 'empty_title', $can_generate ? 'empty_description' :
            $settings->{'schedule'} eq 'manual' ? 'empty_readonly_manual' : 'empty_readonly');
    # Show permitted actions below the message, without icons.
    my @first = grep { $_ } (($data || $log_error) && $can_generate ? &report_generate_form($d, 1) : undef,
                             $can_configure ? &report_settings_link($d) : undef);
    my $actions = @first ? &ui_cluster(\@first, { 'align' => 'center' }) : '';
    if ($log_error) {
        # Show the failed check and keep permitted retry and settings actions.
        print &ui_card({ 'body' =>
            &report_error($text{'log_check_failed'}, $log_error, 'danger').$actions });
    }
    else {
        # Only a successful log check can establish that the site has no traffic.
        print &ui_card({ 'body' => &ui_empty_state({
            'icon' => $icon,
            'title' => $text{$heading},
            'desc' => $text{$description},
            'actions' => $actions || undef }) });
    }
}
print &ui_page_end();
&ui_print_footer('', $text{'index_return'});
