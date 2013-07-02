package MTT::Common;

sub new {
	my $class = shift;
	my $self = { 
		'procTitle' => '',
	};

	bless $self, $class;

	$self->procTitle("Starting");

	return $self;
}

sub tick {
	my ($self) = @_;
	return 1;
}

sub procTitle {
	my ($self, $title) = @_;
	
	if ($title ne $self->{'procTitle'}) {
		$0 = "[MTT] $title";
		$self->{'procTitle'} = $title;
	}
	return 1;
}
1;
