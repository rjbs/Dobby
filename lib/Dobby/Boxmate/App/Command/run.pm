package Dobby::Boxmate::App::Command::run;
use Dobby::Boxmate::App -command;

# ABSTRACT: run a command on a box

use v5.36.0;
use utf8;

use Dobby::Boxmate::TaskStream;

sub abstract { 'run a command on a box' }

sub usage_desc { '%c run %o LABEL COMMAND [ARGS...]' }

sub opt_spec {
  return (
    [ 'username=s',    'run on a box belonging to this user' ],
    [ 'ssh-user=s',    'connect as this ssh user', { default => 'root' } ],
    [ 'taskstream|S',  'interpret TASK:: protocol directives in the output' ],
  );
}

sub validate_args ($self, $opt, $args) {
  @$args >= 2
    || $self->usage->die({ pre_text => "LABEL and COMMAND are required.\n\n" });
}

sub execute ($self, $opt, $args) {
  my $config   = $self->app->config;
  my $boxman   = $self->boxman;
  my $username = $opt->username // $config->username;

  my ($label, @command) = @$args;

  my $droplet = $boxman->_get_droplet_for($username, $label)->get;

  unless ($droplet) {
    die "No droplet for $label.$username exists.\n";
  }

  my $ip       = $boxman->_ip_address_for_droplet($droplet);
  my $ssh_user = $opt->ssh_user;

  my @taskstream_env = $opt->taskstream ? qw( -o SetEnv=FM_TASKSTREAM=1 ) : ();

  my @ssh_cmd = (
    qw(
      ssh
        -o UserKnownHostsFile=/dev/null
        -o StrictHostKeyChecking=no
        -o SendEnv=FM_*
    ),
    @taskstream_env,
    "$ssh_user\@$ip",
    @command,
  );

  my $cb = $opt->taskstream
    ? Dobby::Boxmate::TaskStream->new_taskstream_cb({ loop => $boxman->dobby->loop })
    : sub ($line, @) { print $line if defined $line };

  my ($exitcode) = $boxman->_run_process_streaming(\@ssh_cmd, $cb)->get;

  $cb->(undef, $exitcode == 0 ? 1 : 0);

  exit($exitcode >> 8) if $exitcode;
}

1;
