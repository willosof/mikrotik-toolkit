package MTT::Backup;

sub new {
	my $class = shift;
	my $self = { };

	bless $self, $class;
	return $self;
}

sub tick {
	my ($self) = @_;
	return 1;
}

1;
