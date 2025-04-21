package Dobby::Boxmate::Yakker::Activity::Vestibule;

use Moo;
with 'Yakker::Role::Activity::Commando';

use v5.36.0;

use utf8;

use Yakker::Util qw(
  -cmdctl
  -output

  colored
  colored_prompt
);

use Yakker::Commando -setup => {
  help_sections => [
    { key => '',          title => 'The Basics' },
  ]
};

use Yakker::Commando::Completionist -all;

sub boxman ($self) { $self->app->boxman }

sub prompt_string {
  return colored_prompt(['ansi166'], 'boxmate> ');
}

command 'l.ist' => (
  help    => {
    summary => 'list your boxes',
    text    => "This lists all the boxes marked as owned by your.",
  },
  sub ($self, $cmd, $rest) {
    my $droplets = $self->boxman->get_droplets_for('rjbs')->get; # XXX rjbs

    for my $droplet (@$droplets) {
      my $name   = $droplet->{name};
      my $status = $droplet->{status};
      my $ip     = $droplet->{networks}{v4}[0]{ip_address};
      printf "%20s %15s - %s\n", $name, $ip, $status;
    }
  }
);

command 'c.reate' => (
  help    => {
    summary => 'create a box',
    args    => 'TAG',
    text    => "Destroy the identified box",
  },
  sub ($self, $cmd, $rest) {
    my $tag = length $rest ? $rest : undef;

    # my $spec = Synergy::BoxManager::ProvisionRequest->new({
    #   version   => $version,
    #   tag       => $tag,
    #   size      => $size,
    #   username  => $user->username,
    #   region    => $region,
    #   is_default_box   => $is_default_box,
    #   project_id       => $self->box_project_id,
    #   run_custom_setup => $should_run_setup,
    #   setup_switches   => $switches->{setup},
    # });

    cmderr "Not yet implemented, sorry!";
  }
);

command 'd.estroy' => (
  help    => {
    summary => 'destroy a box',
    args    => 'BOXPREFIX',
    text    => "Destroy the identified box",
  },
  sub ($self, $cmd, $rest) {
    length $rest
      || cmderr 'You need to provide the box prefix, like "user.tag".';

    my ($username, $tag) = split /\./, $rest, 2;
    length $tag || undef $tag;

    # err unless $username = us?
    my $droplet = $self->boxman->_get_droplet_for($username, $tag)->get;

    unless ($droplet) {
      cmderr "Sorry, I didn't find that box.";
    }

    $self->boxman->find_and_destroy_droplet({
      username  => 'rjbs', # XXX rjbs
      tag       => $tag,
      force     => 1,
    })->get;
  }
);

command 'q.uit' => (
  aliases => [ 'exit' ],
  help    => {
    summary => q{eject from abuse review and go do something else},
  },
  sub { Yakker::LoopControl::Empty->new->throw }
);

1;
