#!/usr/bin/perl
# List reports visible to the current Virtualmin user.
use strict;
use warnings;
our %text;
require './virtualmin-goaccess-lib.pl';

&ui_print_header(undef, $text{'index_title'}, '', undef, 1, 1);
my $error = &check_goaccess();
print &ui_alert(&html_escape($error), 'danger') if $error;
my @domains = sort { $a->{'dom'} cmp $b->{'dom'} }
	grep { &allowed_domain($_->{'id'}) } &virtual_server::list_domains();
if (@domains) {
	# Let the theme sort and search reports the current user can access.
	print &ui_columns_start(
		[ $text{'domain'}, $text{'schedule'}, $text{'updated'},
		  $text{'requests'}, $text{'status'} ],
		100, undef, undef, undef, 1);
	foreach my $d (@domains) {
		# Keep listing other domains when one saved report
		# cannot be read.
		my ($settings, $status, $err);
		eval {
			$settings = &load_settings($d);
			$status = &report_status($d);
			};
		$err = $@;
		$status ||= { };
		my $summary = ref($status->{'general'}) eq 'HASH'
			? $status->{'general'}
			: { };
		# Sort dates and counts numerically, including missing reports.
		my $generated = ($status->{'generated'} || '') =~ /\A\d+\z/
			? $status->{'generated'} : 0;
		my $requests = $summary->{'valid_requests'} // '-';
		my $request_order = $requests =~ /\A\d+\z/ ? $requests : -1;
		# Count saved warnings only when the field is an array.
		my $warned = ref($status->{'warnings'}) eq 'ARRAY' &&
			@{$status->{'warnings'}};
		# Unreadable state counts as a failure the
		# administrator should see.
		my $label = $err || $status->{'error'}
			? 'status_error'
			: $d->{'disabled'}
				? 'status_paused'
				: $warned
					? 'status_warning'
					: $status->{'generated'}
						? 'status_ready'
						: 'status_pending';
		print &ui_columns_row([
			&ui_tag('a', &html_escape($d->{'dom'}),
				{ 'href' => 'view.cgi?dom='.$d->{'id'} }),
			&html_escape($settings
				? $text{'schedule_'.$settings->{'schedule'}}
				: '-'),
			$generated
				? &make_date($generated)
				: &html_escape($text{'never'}),
			&html_escape($requests),
			&html_escape($text{$label}) ],
			[ undef, undef, 'data-order="'.$generated.'"',
			  'data-order="'.$request_order.'"' ]);
		}
	print &ui_columns_end();
	}
else {
	# Explain why there are no reports to list.
	print &ui_empty_state({
		'icon' => 'globe',
		'title' => $text{'index_empty_title'},
		'desc' => $text{'index_empty'} });
	}
&ui_print_footer('/', $text{'index'});
