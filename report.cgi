#!/usr/bin/perl
# Serve a private standalone report after checking domain permissions.
use strict;
use warnings;
our (%in, %text);
require './virtualmin-goaccess-lib.pl';
&ReadParse();
my $d = &require_domain($in{'dom'});
my $path = &domain_dir($d).'/report.html';
my $html = eval { GoAccess::Report::read_regular($path, 256*1024*1024) };
&error($text{'report_missing'}) if $@;

# Inside Webmin the report follows the theme. Inline assets apply the palette
# that the report page sends; downloads stay exactly as GoAccess made them.
if (!$in{'download'}) {
    my $assets = &frame_assets();
    my $head = index($html, '</head>');
    $head = index(lc(substr($html, 0, 1024*1024)), '</head>') if $head < 0;
    if ($head >= 0) {
        substr($html, $head, 0, $assets);
    }
    else {
        $html = $assets.$html;
    }
}

# Keep report JavaScript isolated even when the report URL is opened directly.
# GoAccess's template engine needs eval; the opaque origin and network block
# still prevent its scripts from reaching Webmin or other services.
print "Content-Type: text/html; charset=UTF-8\r\n";
print "Cache-Control: private, no-store\r\n";
print "X-Content-Type-Options: nosniff\r\n";
print "Referrer-Policy: no-referrer\r\n";
print "Content-Security-Policy: sandbox allow-scripts allow-downloads; default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; base-uri 'none'; form-action 'none'\r\n";
print "Content-Disposition: attachment; filename=\"goaccess-$d->{'id'}.html\"\r\n" if $in{'download'};
print "\r\n";
print $html;
