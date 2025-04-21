package Dobby::Boxmate::App::Command::shell;
use Dobby::Boxmate::App -command;

use v5.36.0;

sub abstract { 'start the interactive box shell' }

sub execute ($self, $opt, $arg) {
  require Dobby::Boxmate::Yakker::App;
  Dobby::Boxmate::Yakker::App->run({
    boxman => $self->app->boxman,
  });
}

1;
