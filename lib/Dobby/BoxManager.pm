package Dobby::BoxManager;
use Moose;

use v5.36.0;
use utf8;

use Carp ();
use Dobby::Client;
use Future::AsyncAwait;
use IO::Async::Process;
use Path::Tiny;
use Process::Status;

has dobby => (
  is => 'ro',
  required => 1,
);

# This is not here so we can set it to zero and get rate limited or see bugs in
# production.  It's here so we can make the tests run fast. -- rjbs, 2024-02-09
has post_creation_delay => (
  is => 'ro',
  default => 5,
);

has box_domain => (
  is       => 'ro',
  isa      => 'Str',
  required => 1,
);

# error   - report to the user and stop processing
# message - report to the user and continue
# log     - write to syslog, continue; args may be String::Flogger-ed
for my $type (qw( error log message )) {
  has "$type\_cb" => (
    is  => 'ro',
    isa => 'CodeRef',
    required => 1,
    traits   => [ 'Code' ],
    handles  => {
      "handle_$type" => 'execute',
    },
  );
}

# taskstream_cb is called repeatedly with complete-line chunks as they arrive
# from the setup process.  When the process exits it is called once more with
# (undef, $success_bool) to signal end-of-stream and convey the outcome.
#
# logsnippet_cb is called once at completion (success or failure) with
# (\$accumulated_text, { success => $bool }).
#
# Exactly one of these must be provided; see BUILD.
has taskstream_cb => (
  is        => 'ro',
  isa       => 'CodeRef',
  predicate => 'has_taskstream_cb',
);

has logsnippet_cb => (
  is        => 'ro',
  isa       => 'CodeRef',
  predicate => 'has_logsnippet_cb',
);

sub BUILD ($self, @) {
  unless ($self->has_taskstream_cb || $self->has_logsnippet_cb) {
    Carp::confess("BoxManager requires one of taskstream_cb or logsnippet_cb but neither was provided");
  }

  if ($self->has_taskstream_cb && $self->has_logsnippet_cb) {
    Carp::confess("BoxManager requires one of taskstream_cb or logsnippet_cb but both were provided");
  }
}

after "handle_error" => sub ($self, $error_str, @) {
  # The error_cb should always die, meaning this should never be reached.  If
  # it is, it means somebody wrote an error_cb that doesn't die, so it is our
  # job to die on their behalf.  Like in that movie Infinity Pool.
  die "error_cb did not throw an error for: $error_str";
};

package Dobby::BoxManager::ProvisionRequest {
  use Moose;

  # This is here for sort of easy last minute validation.  It doesn't check
  # things like "what if the user said to run custom setup but not standard
  # setup".  At some point, you'll get weird results if you do weird things.

  has region      => (is => 'ro', isa => 'Str',     required => 1);
  has size        => (is => 'ro', isa => 'Str',     required => 1);
  has username    => (is => 'ro', isa => 'Str',     required => 1);
  has version     => (is => 'ro', isa => 'Str',     required => 1);

  has image_id    => (is => 'ro', isa => 'Str',     required => 0);

  has label       => (is => 'ro', isa => 'Str',     required => 1);

  has extra_tags  => (is => 'ro', isa => 'ArrayRef[Str]', default => sub { [] });
  has project_id  => (is => 'ro', isa => 'Maybe[Str]');

  has is_default_box   => (is => 'ro', isa => 'Bool', default => 0);
  has run_custom_setup => (is => 'ro', isa => 'Bool', default => 0);
  has setup_switches   => (is => 'ro', isa => 'Maybe[ArrayRef]');

  has run_standard_setup => (is => 'ro', isa => 'Bool', default => 1);

  has ssh_key_id => (is  => 'ro', isa => 'Str', predicate => 'has_ssh_key_id');
  has digitalocean_ssh_key_name => (is  => 'ro', isa => 'Str', default => 'synergy');

  no Moose;
  __PACKAGE__->meta->make_immutable;
}

async sub create_droplet ($self, $spec) {
  my $maybe_droplet = await $self->_get_droplet_for($spec->username, $spec->label);

  if ($maybe_droplet) {
    $self->handle_error(
      "This box already exists: " . $self->_format_droplet($maybe_droplet)
    );
  }

  my $name = $self->box_name_for($spec->username, $spec->label);

  my $region = $spec->region;
  $self->handle_message("Creating $name in \U$region\E, this will take a minute or two.");

  # It would be nice to do these in parallel, but in testing that causes
  # *super* strange errors deep down in IO::Async if one of the calls fails and
  # the other does not, so here we'll just admit defeat and do them in
  # sequence. -- michael, 2020-04-02
  my $snapshot_id = await $self->_get_snapshot_id($spec);
  my $ssh_key  = await $self->_get_ssh_key($spec);

  # We get this early so that we don't bother creating the Droplet if we're not
  # going to be able to authenticate to it.
  my $key_file = $self->_get_my_ssh_key_file($spec);

  my %droplet_create_args = (
    name     => $name,
    region   => $spec->region,
    size     => $spec->size,
    image    => $snapshot_id,
    ssh_keys => [ $ssh_key->{id} ],
    tags     => [ "owner:" . $spec->username, $spec->extra_tags->@* ],
  );

  $self->handle_log([ "creating droplet: %s", \%droplet_create_args ]);

  my $droplet = await $self->dobby->create_droplet(\%droplet_create_args);

  unless ($droplet) {
    $self->handle_error("There was an error creating the box. Try again.");
  }

  # We delay this because a completed droplet sometimes does not show up in GET
  # /droplets immediately, which causes annoying problems.  Waiting 5s is a
  # silly fix, but seems to work, and it's not like box creation is
  # lightning-fast anyway. -- michael, 2021-04-16
  await $self->dobby->loop->delay_future(after => $self->post_creation_delay);

  $droplet = await $self->_get_droplet_for($spec->username, $spec->label);

  if ($droplet) {
    $self->handle_log([ "created droplet %s (%s)", $droplet->{id}, $droplet->{name} ]);
  } else {
    # We don't fail here, because we want to try to update DNS regardless.
    $self->handle_message(
      "Box was created, but now I can't find it! Check the DigitalOcean console and maybe try again."
    );
  }

  # Add it to the relevant project. If this fails, then...oh well.
  # -- ?
  if ($spec->project_id) {
    await $self->dobby->add_droplet_to_project(
      $droplet->{id},
      $spec->project_id
    );
  }

  {
    # update the DNS name. we will assume this succeeds; if it fails the box is
    # still good and there's not really much else we can do.
    my $box_domain = $self->box_domain;

    my $ip_addr = $self->_ip_address_for_droplet($droplet);

    my $name = $self->_dns_name_for($spec->username, $spec->label);
    $self->handle_log("setting up A records for $name.$box_domain");

    await $self->dobby->point_domain_record_at_ip($box_domain, $name, $ip_addr);

    if ($spec->is_default_box) {
      my $cname = $spec->username;
      $self->handle_log("setting up CNAME records for $cname.$box_domain");

      # You *must* provide the trailing dot when *creating* the record, but
      # *not* when destroying it.  I suppose there's a way in which this is
      # defensible, but it bugs me. -- rjbs, 2025-04-22
      await $self->dobby->point_domain_record_at_name($box_domain, $cname, "$name.$box_domain.");
    }
  }

  my $message  = $spec->run_custom_setup   ? "Box created, will now run setup. Your box is: "
               :                             "Box created, will now unlock.  Your box is: ";
  if ($spec->run_standard_setup or $spec->run_custom_setup) {
    $self->handle_message(
      $message . $self->_format_droplet($droplet)
    );

    return await $self->_setup_droplet(
      $spec,
      $droplet,
      $key_file,
    );
  }

  # We didn't have to run any setup!
  $self->handle_message(
    "Box created. Your box is: " . $self->_format_droplet($droplet)
  );

  return;
}

async sub _get_snapshot_id ($self, $spec) {
  if (defined $spec->image_id) {
    return $spec->image_id;
  }

  my $region = $spec->region;

  my $snapshot = await $self->get_snapshot_for_version($spec->version);
  my %snapshot_regions = map {; $_ => 1 } $snapshot->{regions}->@*;

  unless ($snapshot_regions{$region}) {
    my $region_list = join q{, }, map {; uc } sort $snapshot->{regions}->@*;
    $self->handle_error("The snapshot you want ($snapshot->{name}) isn't available in \U$region\E.  You could create it in any of these regions: $region_list");
  }

  return $snapshot->{id};
}

sub _get_my_ssh_key_file ($self, $spec) {
  # If we don't have a key id specified, we'll just let ssh pick.  We need this
  # for agents like Secretive, which don't expose the privkey as a file that
  # can be specified with ssh's -i argument.
  return undef unless $spec->has_ssh_key_id;

  my $key_file = path($spec->ssh_key_id)->absolute("$ENV{HOME}/.ssh/");

  unless (-r $key_file) {
    $self->handle_log(["Cannot read SSH key for inabox setup (from %s)", $spec->ssh_key_id]);
    $self->handle_error(
      "No SSH credentials for running box setup. This is a problem - aborting."
    );
  }

  return $key_file;
}

async sub _setup_droplet ($self, $spec, $droplet, $key_file) {
  my $ip_address = $self->_ip_address_for_droplet($droplet);

  my $args = $spec->setup_switches // [];
  unless ($self->_validate_setup_args($args)) {
    $self->handle_message("Your /setup arguments don't meet my strict and undocumented requirements, sorry.  I'll act like you provided none.");
    $args = [];
  }

  my $success;
  my $max_tries = 20;
  TRY: for my $try (1..$max_tries) {
    my $socket;
    eval {
      $socket = await $self->dobby->loop->connect(addr => {
        family   => 'inet',
        socktype => 'stream',
        port     => 22,
        ip       => $ip_address,
      });
    };

    if ($socket) {
      # We didn't need the connection, just to know it worked!
      undef $socket;

      $self->handle_log([
        "ssh on %s is up, will now move on to running setup",
        $ip_address,
      ]);

      $success = 1;

      last TRY;
    }

    my $error = $@;
    if ($error !~ /Connection refused/) {
      $self->handle_log([
        "weird error connecting to %s:22: %s",
        $ip_address,
        $error,
      ]);
    }

    if ($try == $max_tries) {
      $self->handle_log([ "ssh on %s is not up", $ip_address ]);
      last TRY;
    }

    $self->handle_log([
      "ssh on %s is not up, will wait and try again; %s tries remain",
      $ip_address,
      $max_tries - $try,
    ]);

    await $self->dobby->loop->delay_future(after => 1);
  }

  unless ($success) {
    # Really, this is an error, but when called in Synergy, we wouldn't want
    # the user to be able to edit the "box create" message and try again.  The
    # Droplet was created, but now it's weirdly inaccessible.
    $self->handle_message("I couldn't connect to your box to set it up. A human will need to clean this up!");
    return;
  }

  my @setup_args = $spec->run_custom_setup ? () : ('--no-custom');

  my @ssh_command = (
    "ssh",
      '-A',
      (defined $key_file ? ('-i', "$key_file") : ()),
      '-l', 'root',
      '-o', 'UserKnownHostsFile=/dev/null',
      '-o', 'StrictHostKeyChecking=no',
      '-o', 'ControlMaster=no',
      '-o', 'SetEnv=FM_TASKSTREAM=1',

    $ip_address,
    (
      qw( fmdev mysetup ),
      '--user', $spec->username,
      @setup_args,
      '--',
      @$args
    ),
  );

  $self->handle_log([ "about to run ssh: %s", \@ssh_command ]);

  my $taskstream_cb;
  if ($self->has_taskstream_cb) {
    $taskstream_cb = $self->taskstream_cb;
  } else {
    # Only logsnippet_cb: synthesize a streaming callback around it.

    my $buffer = '';
    $taskstream_cb = sub ($line, $success = undef) {
      if (defined $line) { $buffer .= $line }
      else               { $self->logsnippet_cb->(\$buffer, { success => $success }) }
    };
  }

  my $exitcode = await $self->_run_process_streaming(
    \@ssh_command,
    $taskstream_cb,
  );

  my $exit_success = ($exitcode == 0) ? 1 : 0;
  $taskstream_cb->(undef, $exit_success);  # end-of-stream sentinel

  $self->handle_log([ "result of ssh: %s", Process::Status->new($exitcode)->as_string ]);

  if ($exitcode == 0) {
    $self->handle_message(
      $spec->run_custom_setup ? "Box ($droplet->{name}) is now set up!"
      : "Box ($droplet->{name}) is ready!"
    );
    return;
  }

  $self->handle_message("Something went wrong setting up your box.");

  return;
}

# Run $command as a subprocess, calling $line_cb->($line) for each complete
# line of stdout as it arrives.  Returns ($exitcode)
#
# This provides the same callback for stdout and stderr, effectively merging
# their streams, even though those could be desynchronized.  We expect that the
# programs that will be run will be setting fd 2 == fd 1, making this a
# non-issue, but it can't be guaranteed.  No option seemed like a good option,
# so I went with the one with the least code. -- rjbs, 2026-02-21
async sub _run_process_streaming ($self, $command, $line_cb, %opts) {
  my $partial = '';
  my $exit_future = $self->dobby->loop->new_future;

  my $reader = sub ($stream, $buffref, $eof) {
    $partial .= $$buffref;
    $$buffref = '';
    while ($partial =~ s/\A([^\n]*\n)//) {
      $line_cb->($1);
    }
    return 0;
  };

  my $process = IO::Async::Process->new(
    command => $command,
    stdout  => { on_read => $reader },
    stderr  => { on_read => $reader },
    on_finish => sub ($proc, $exitcode) { $exit_future->done($exitcode) },
  );

  $self->dobby->loop->add($process);

  my $exitcode = await $exit_future;

  # Flush any partial line left over when the process exited without a
  # trailing newline.
  $line_cb->($partial) if length $partial;

  return $exitcode;
}

async sub find_and_destroy_droplet ($self, $arg) {
  my $username = $arg->{username};
  my $label    = $arg->{label};
  my $force    = $arg->{force};

  my $droplet = await $self->_get_droplet_for($username, $label);

  unless ($droplet) {
    $self->handle_error(
      "That box doesn't exist: " . $self->box_name_for($username, $label)
    );
  }

  await $self->destroy_droplet($droplet, { force => $arg->{force} });
}

async sub destroy_droplet ($self, $droplet, $arg) {
  my $can_destroy = $arg->{force} || $droplet->{status} ne 'active';

  unless ($can_destroy) {
    $self->handle_error(
      "That box is powered on. Shut it down first, or use force to destroy it anyway."
    );
  }

  my $ip_addr = $self->_ip_address_for_droplet($droplet);
  $self->handle_log([ "destroying DNS records pointing to %s", $ip_addr ]);
  await $self->dobby->remove_domain_records_for_ip(
    $self->box_domain,
    $self->_ip_address_for_droplet($droplet),
  );

  # Is it safe to assume $droplet->{name} is the target name?  I think so,
  # given the create code. -- rjbs, 2025-04-22
  my $dns_name = $droplet->{name};
  $self->handle_log([ "destroying CNAME records pointing to %s", $dns_name ]);
  await $self->dobby->remove_domain_records_cname_targeting($self->box_domain, $dns_name);

  $self->handle_log([ "destroying droplet %s (%s)", $droplet->{id}, $droplet->{name} ]);

  await $self->dobby->destroy_droplet($droplet->{id});

  $self->handle_log([ "destroyed droplet: %s", $droplet->{id} ]);

  $self->handle_message("Box destroyed: " . $droplet->{name});
  return;
}

async sub take_droplet_action ($self, $username, $label, $action) {
  my $gerund = $action eq 'on'       ? 'powering on'
             : $action eq 'off'      ? 'powering off'
             : $action eq 'shutdown' ? 'shutting down'
             : die "unknown power action $action!";

  my $past_tense = $action eq 'shutdown' ? 'shut down' : "powered $action";

  my $droplet = await $self->_get_droplet_for($username, $label);

  unless ($droplet) {
    $self->handle_error("I can't find a box to do that to!");
  }

  my $expect_off = $action eq 'on';

  if ( (  $expect_off && $droplet->{status} eq 'active')
    || (! $expect_off && $droplet->{status} ne 'active')
  ) {
    $self->handle_error("That box is already $past_tense!");
  }

  $self->handle_log([ "$gerund droplet: %s", $droplet->{id} ]);

  $self->handle_message("I've started $gerund that box…");

  my $method = $action eq 'shutdown' ? 'shutdown' : "power_$action";

  eval {
    await $self->dobby->take_droplet_action($droplet->{id}, $method);
  };

  if (my $error = $@) {
    $self->handle_log([
      "error when taking %s action on droplet: %s",
      $method,
      $@,
    ]);

    $self->handle_error(
      "Something went wrong while $gerund box, check the DigitalOcean console and maybe try again.",
    );
  }

  $self->handle_message("That box has been $past_tense.");

  return;
}

async sub mollyguard_status_for ($self, $droplet) {
  my $ip  = $self->_ip_address_for_droplet($droplet);

  my @ssh_command = (
    qw(
      ssh
        -o UserKnownHostsFile=/dev/null
        -o StrictHostKeyChecking=no
        -o SendEnv=FM_*
    ),
    "root\@$ip",
    <<~'END',
      if [ -e /home/mod_perl/hm/ME/App/FMDev/Command/mollyguard.pm ]; then
        fmdev mollyguard;
      else
        true
      fi
    END
  );

  my ($exitcode, $stdout, $stderr) = await $self->dobby->loop->run_process(
    capture => [ qw( exitcode stdout stderr ) ],
    command => [ @ssh_command ],
  );

  return { ok => 1 } if $exitcode == 0;

  my $content = $stderr;
  $content .= "\n\n----(stdout)----\n$stdout" if length $stdout;

  $content = Encode::decode('utf-8', $content);

  return {
    ok     => 0,
    report => $content,
  };
}

async sub _get_ssh_key ($self, $spec) {
  my $dobby = $self->dobby;
  my $keys = await $dobby->json_get_pages_of("/account/keys", 'ssh_keys');

  my $want_key = $spec->digitalocean_ssh_key_name;
  my ($ssh_key) = grep {; $_->{name} eq $want_key } @$keys;

  if ($ssh_key) {
    $self->handle_log([ "found SSH key %s (%s)", $ssh_key->@{ qw(id name) } ]);
    return $ssh_key;
  }

  $self->handle_log("fminabox SSH key not found?!");
  $self->handle_error("Hmm, I couldn't find a DO ssh key to use for fminabox!");
}

sub _dns_name_for ($self, $username, $label) {
  length $username
    || Carp::confess("username was undef or empty in call to _dns_name_for");

  length $label
    || Carp::confess("label was undef or empty in call to _dns_name_for");

  return join '.', $label, $username;
}

sub box_name_for ($self, $username, $label = undef) {
  my $stub = length $label ? $self->_dns_name_for($username, $label) : $username;
  return join '.', $stub, $self->box_domain;
}

async sub _get_droplet_for ($self, $username, $label) {
  my $name = $self->box_name_for($username, $label);

  my $droplets = await $self->get_droplets_for($username);

  my ($droplet) = grep {; $_->{name} eq $name } @$droplets;

  return $droplet;
}

async sub get_droplets_for ($self, $username) {
  my $dobby = $self->dobby;
  my $tag   = "owner:$username";

  my @droplets = await $dobby->get_droplets_with_tag($tag);

  return \@droplets;
}

async sub get_snapshot_for_version ($self, $version) {
  my $dobby = $self->dobby;
  my $snaps = await $dobby->json_get_pages_of('/snapshots', 'snapshots');

  my ($snapshot) = sort { $b->{created_at} cmp $a->{created_at} }
                   grep { $_->{name} =~ m/^fminabox-\Q$version\E/ }
                   @$snaps;

  if ($snapshot) {
    return $snapshot;
  }

  $self->handle_error("no snapshot found for fminabox-$version");
}

sub _ip_address_for_droplet ($self, $droplet) {
  # we want the public address, not the internal VPC address that we don't use
  my ($ip_address) =
    map { $_->{ip_address} }
    grep { $_->{type} eq 'public'}
      $droplet->{networks}{v4}->@*;
  return $ip_address;
}

sub _format_droplet ($self, $droplet) {
  return sprintf
    "name: %s  image: %s  ip: %s  region: %s  status: %s",
    $droplet->{name},
    $droplet->{image}{name},
    $self->_ip_address_for_droplet($droplet),
    "$droplet->{region}{name} ($droplet->{region}{slug})",
    $droplet->{status};
}

sub _validate_setup_args ($self, $args) {
  return !! (@$args == grep {; /\A[-.a-zA-Z0-9]+\z/ } @$args);
}

1;
