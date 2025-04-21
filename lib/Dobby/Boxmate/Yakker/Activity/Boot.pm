package Dobby::Boxmate::Yakker::Activity::Boot;
use Moo;
with 'Yakker::Role::Activity';

use v5.36.0;
use utf8;

use Dobby::BoxManager;
use IO::Async;
use IO::Async::Loop;
use String::Flogger ();

use Yakker::Util qw(
  matesay
  errsay
  okaysay
);

sub interact ($self) {
  matesay "Welcome to Box Central.";

  my $activity = $self->app->activity('vestibule');

  Yakker::LoopControl::Swap->new({ activity => $activity })->throw;
}

no Moo;
1;
