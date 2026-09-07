use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use IO::Compress::Gzip qw(gzip $GzipError);
use FindBin;
use lib "$FindBin::Bin/..";
use GoAccess::Report;

my $settings = GoAccess::Report::defaults();
is($settings->{format}, 'COMBINED', 'combined log format by default');
ok($settings->{anonymize} && $settings->{no_query}, 'privacy options on by default');
is_deeply(GoAccess::Report::validate({}), $settings, 'missing settings receive defaults');
my $filtered = GoAccess::Report::validate({binary => '/unused', output => '/unused'});
ok(!exists($filtered->{binary}) && !exists($filtered->{output}), 'only supported options are accepted');

# Invalid forms must fail before a parser or schedule is changed.
foreach my $invalid ({format => 'unknown'}, {schedule => '* * * * *'},
    {anonymize => 2}, {keep_days => -1},
    {keep_days => 3661}, {max_items => 9}, {max_items => 1001},
    {custom_format => "line\nline"}, {format => 'CUSTOM'}, {rotated => []}) {
    eval { GoAccess::Report::validate($invalid); };
    ok($@, 'invalid settings rejected: '.join(', ', keys %$invalid));
}
done_testing();
