use v5.36.0;
use utf8;

use lib 't/lib';

use Dobby::BoxManager;
use Dobby::TestClient;

use Test::More;
use Test::Deep ':v1';

# Sizes are named for their relative cost to make tests easy to read.  Fields
# are set to make each filter test unambiguous: e.g. only 'large' and 'xlarge'
# have vcpus >= 4, disk >= 100, or memory >= 8 GB.
my $sizes_page = {
  sizes => [
    { slug => 'small',  available => 1, regions => [qw(nyc sfo)],
      price_hourly => 0.02, vcpus => 1, disk =>  25, memory =>  1024 },
    { slug => 'medium', available => 1, regions => [qw(nyc sfo ams)],
      price_hourly => 0.05, vcpus => 2, disk =>  50, memory =>  4096 },
    { slug => 'large',  available => 1, regions => [qw(nyc sfo ams)],
      price_hourly => 0.10, vcpus => 4, disk => 100, memory =>  8192 },
    { slug => 'xlarge', available => 1, regions => [qw(nyc)],
      price_hourly => 0.20, vcpus => 8, disk => 200, memory => 16384 },
    { slug => 'gone',   available => 0, regions => [qw(nyc sfo ams)],
      price_hourly => 0.03, vcpus => 2, disk =>  50, memory =>  4096 },
  ],
};

my sub _get_set (%args) {
  my $dobby = Dobby::TestClient->new(bearer_token => 'test-token');
  $dobby->register_url_json('/sizes', $sizes_page);

  my $boxman = Dobby::BoxManager->new(
    dobby         => $dobby,
    box_domain    => 'fm.example.com',
    error_cb      => sub ($err, @) { die $err },
    message_cb    => sub { },
    log_cb        => sub { },
    logsnippet_cb => sub { },
  );

  return $boxman->find_provisioning_candidates(%args)->get;
}

# Shorthand for a candidate with the given size and region (ignoring other fields).
sub pair ($size, $region) {
  return superhashof({ size => $size, region => $region });
}

sub candidates_ok ($args, $expect, $description) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;
  cmp_deeply(
    [ _get_set(%$args)->candidates ],
    $expect,
    "$description: got the expected candidate set",
  );
}

sub pick_ok ($args, $expect, $description) {
  local $Test::Builder::Level = $Test::Builder::Level + 1;
  cmp_deeply(
    _get_set(%$args)->pick_one,
    $expect,
    "$description: picked the expected candidate",
  );
}

candidates_ok(
  {},
  bag(
    pair('small',  'nyc'), pair('small',  'sfo'),
    pair('medium', 'nyc'), pair('medium', 'sfo'), pair('medium', 'ams'),
    pair('large',  'nyc'), pair('large',  'sfo'), pair('large',  'ams'),
    pair('xlarge', 'nyc'),
  ),
  'no filters: all available sizes in all their regions; unavailable excluded',
);

candidates_ok(
  { max_price => 0.05 },
  bag(
    pair('small',  'nyc'), pair('small',  'sfo'),
    pair('medium', 'nyc'), pair('medium', 'sfo'), pair('medium', 'ams'),
  ),
  'max_price excludes sizes above the limit',
);

candidates_ok(
  { min_price => 0.05 },
  bag(
    pair('medium', 'nyc'), pair('medium', 'sfo'), pair('medium', 'ams'),
    pair('large',  'nyc'), pair('large',  'sfo'), pair('large',  'ams'),
    pair('xlarge', 'nyc'),
  ),
  'min_price excludes sizes below the limit',
);

candidates_ok(
  { min_cpu => 4 },
  bag(
    pair('large',  'nyc'), pair('large',  'sfo'), pair('large',  'ams'),
    pair('xlarge', 'nyc'),
  ),
  'min_cpu excludes sizes with fewer vcpus',
);

candidates_ok(
  { min_disk => 100 },
  bag(
    pair('large',  'nyc'), pair('large',  'sfo'), pair('large',  'ams'),
    pair('xlarge', 'nyc'),
  ),
  'min_disk excludes sizes with smaller disks',
);

candidates_ok(
  { min_ram => 8 },
  bag(
    pair('large',  'nyc'), pair('large',  'sfo'), pair('large',  'ams'),
    pair('xlarge', 'nyc'),
  ),
  'min_ram excludes sizes below the threshold (arg is GB, API uses MB)',
);

candidates_ok(
  { snapshot => { name => 'test-snap', regions => [qw(nyc)] } },
  bag(
    pair('small',  'nyc'),
    pair('medium', 'nyc'),
    pair('large',  'nyc'),
    pair('xlarge', 'nyc'),
  ),
  'snapshot restricts candidates to regions where it is available',
);

candidates_ok(
  { size_preferences => [qw(small large)] },
  bag(
    pair('small', 'nyc'), pair('small', 'sfo'),
    pair('large', 'nyc'), pair('large', 'sfo'), pair('large', 'ams'),
  ),
  'size_preferences restricts candidates to those slugs only',
);

candidates_ok(
  { region_preferences => [qw(ams)] },
  bag(
    pair('medium', 'ams'),
    pair('large',  'ams'),
  ),
  'region_preferences without fallback restricts to preferred regions only',
);

candidates_ok(
  {
    region_preferences   => [qw(ams)],
    fallback_to_anywhere => 1,
  },
  bag(
    pair('small',  'nyc'), pair('small',  'sfo'),
    pair('medium', 'nyc'), pair('medium', 'sfo'), pair('medium', 'ams'),
    pair('large',  'nyc'), pair('large',  'sfo'), pair('large',  'ams'),
    pair('xlarge', 'nyc'),
  ),
  'fallback_to_anywhere with region_preferences includes all valid regions',
);

# With max_price=0.06, small(0.02) and medium(0.05) are candidates.
# No size preferences, so price alone decides: small wins.
pick_ok(
  { max_price => 0.06 },
  pair('small', ignore()),
  'no size preferences: cheapest candidate wins',
);

# large is preferred over small despite costing more.
pick_ok(
  { size_preferences => [qw(large small)] },
  pair('large', ignore()),
  'size preference rank beats price',
);

# prefer_proximity=1: ams is the preferred region.  medium and large are both
# in ams; medium(0.05) is cheaper, so it wins.
pick_ok(
  {
    region_preferences => [qw(ams)],
    prefer_proximity   => 1,
  },
  pair('medium', 'ams'),
  'prefer_proximity: preferred region is primary, cheapest size in that region wins',
);

done_testing;
