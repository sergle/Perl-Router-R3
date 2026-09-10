# match() used to leak the str_array token array (allocated by str_array_create(),
# grown by str_array_resize(), never freed by str_array_free()) on every call:
# 48 bytes per match with the default capacity of 3, 208 bytes once the array is
# resized. This test drives each match() shape and fails if RSS keeps growing.

use strict;
use warnings;

use English qw( $OS_ERROR );
# the plan is set at import time because use_ok() below runs at compile time:
# a runtime plan would be printed in the middle of the TAP output
use Test::More -r '/proc/self/status'
    ? ( tests    => 8 )
    : ( skip_all => 'RSS measurement needs /proc/self/status' );

BEGIN { use_ok('Router::R3') };

# iterations per shape; a 48 bytes/call leak shows up as ~9.6 MB of RSS growth
my $ITERATIONS = 200_000;

# tolerance, bytes per call: the leak is 48 bytes/call at least, so anything
# below this is allocator noise rather than the bug
my $MAX_BYTES_PER_CALL = 4;

sub rss_kb {
    open my $fh, '<', '/proc/self/status' or die "open /proc/self/status: $OS_ERROR";
    my $kb;
    while( <$fh> ) {
        $kb = $1 if /^VmRSS:\s+(\d+)/;
    }
    close $fh;
    return $kb;
}

my $router = Router::R3->new(
    '/static'                            => 'static',
    '/one/{id:\d+}'                      => 'one',
    '/three/{a}/{b}/{c}'                 => 'three',
    '/five/{a}/{b}/{c}/{d}/{e}'          => 'five',
);

sub match_does_not_leak {
    my($path, $name) = @_;

    # warm up: first calls populate the pcre caches and the malloc arena
    $router->match($path) for 1 .. 5_000;

    my $before = rss_kb();
    $router->match($path) for 1 .. $ITERATIONS;
    my $growth = ( rss_kb() - $before ) * 1024 / $ITERATIONS;

    cmp_ok( $growth, '<', $MAX_BYTES_PER_CALL, sprintf( '%s: %.1f bytes/call', $name, $growth ) );
}

# behaviour is unchanged by the fix - the freed array must not be the one still in use
my($match, $capture) = $router->match('/five/1/2/3/4/5');
is( $match, 'five', 'captured route still matches' );
is( $capture->{e}, 5, 'last capture still returned' );

# every shape: with and without captures, below and above the initial capacity
# of 3 (which is where str_array_resize() replaces the array), and no match at
# all - the match_entry is allocated before the tree walk, so 404s leaked too
match_does_not_leak( '/static',          'no captures' );
match_does_not_leak( '/one/42',          'one capture' );
match_does_not_leak( '/three/1/2/3',     'three captures' );
match_does_not_leak( '/five/1/2/3/4/5',  'five captures, resized array' );
match_does_not_leak( '/nowhere',         'no match' );
