# Supply a permitted domain to Webmin's CGI discovery.
use strict;
use warnings;
require 'virtualmin-goaccess-lib.pl';

# cgi_args(cgi) returns safe example arguments for a read-only page.
sub cgi_args
{
my ($cgi) = @_;
# The index needs no arguments. Advertise view pages, excluding POST actions.
return undef if $cgi eq 'index.cgi';
return 'none' unless $cgi =~ /\A(?:view|edit|report)\.cgi\z/;
my ($d) = grep { &allowed_domain($_->{'id'}) } &virtual_server::list_domains();
return $d ? 'dom='.$d->{'id'} : 'none';
}

1;
