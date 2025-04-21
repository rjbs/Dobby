package Dobby::Boxmate::Yakker::App;
use Moo;

use v5.36.0;

use Yakker ();
with 'Yakker::App';

use Dobby::Boxmate::Yakker::Activity::Boot;
use Dobby::Boxmate::Yakker::Activity::Vestibule;

sub name { 'boxmate' }

has boxman => (
  is => 'ro',
  required => 1,
);

sub activity_class ($self, $name) {
  state %CLASS = (
    boot       => 'Dobby::Boxmate::Yakker::Activity::Boot',
    vestibule  => 'Dobby::Boxmate::Yakker::Activity::Vestibule',
  );

  return $CLASS{$name}
}

no Moo;
1;
