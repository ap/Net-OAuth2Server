use strict; use warnings;

package Net::OAuth2Server::Request;
use Net::OAuth2Server::Set ();
use Net::OAuth2Server::Response ();
use MIME::Base64 ();
use Carp ();

sub request_body_methods  { 'POST' }
sub allowed_methods       {}
sub accepted_auth         {}
sub required_parameters   {}
sub required_confidential {}
sub set_parameters        { 'scope' }

use Object::Tiny::Lvalue qw( method headers parameters confidential scope error );

my $loaded;
sub from_psgi {
	my ( $class, $env ) = ( shift, @_ );
	my $body;
	$body = do { $loaded ||= require Plack::Request; Plack::Request->new( $env )->content }
		if 'application/x-www-form-urlencoded' eq ( $env->{'CONTENT_TYPE'} || '' )
		and grep $env->{'REQUEST_METHOD'} eq $_, $class->request_body_methods;
	$class->from(
		$env->{'REQUEST_METHOD'},
		$env->{'QUERY_STRING'},
		{ map /\A(?:HTTPS?_)?((?:(?!\A)|\ACONTENT_).*)/s ? ( "$1", $env->{ $_ } ) : (), keys %$env },
		$body,
	);
}

my %auth_parser = ( # XXX not sure about this design...
	Bearer => sub { [ access_token => $_[0] ] },
	Basic  => sub {
		my @k = qw( client_id client_secret );
		my @v = split /:/, MIME::Base64::decode( $_[0] ), 2;
		[ map { ( shift @k, $_ ) x ( '' ne $_ ) } @v ];
	},
);

sub from {
	my ( $class, $meth, $query, $hdr, $body ) = ( shift, @_ );

	Carp::croak 'missing request method' unless defined $meth and '' ne $meth;

	%$hdr = map { my $k = $_; y/-/_/; ( lc, $hdr->{ $k } ) } $hdr ? keys %$hdr : ();

	undef $body
		if ( not grep $meth eq $_, $class->request_body_methods )
		or 'application/x-www-form-urlencoded' ne ( $hdr->{'content_type'} || '' );

	for ( $query, $body ) {
		defined $_ ? y/+/ / : ( $_ = '' );
		# parse to k/v pairs, ignoring empty pairs, ensuring both k&v are always defined
		$_ = [ / \G (?!\z) [&;]* ([^=&;]*) =? ([^&;]*) (?: [&;]+ | \z) /xg ];
		s/%([0-9A-Fa-f]{2})/chr hex $1/ge for @$_;
	}

	my $auth = $class->accepted_auth;
	if ( $auth and ( $hdr->{'authorization'} || '' ) =~ /\A\Q$auth\E +([^ ]+) *\z/ ) {
		my $parser = $auth_parser{ $auth }
			or Carp::croak "unsupported HTTP Auth type '$auth' requested in $class";
		$auth = $parser->( "$1" );
	}
	else { $auth = [] }

	my ( %param, %visible, %dupe );
	for my $list ( $auth, $body, $query ) {
		while ( @$list ) {
			my ( $name, $value ) = splice @$list, 0, 2;
			if ( exists $param{ $name } and $value ne $param{ $name } ) {
				$dupe{ $name } = 1;
			}
			else {
				$param{ $name } = $value;
				$visible{ $name } = 1 if $list == $query;
			}
		}
	}

	if ( my @dupe = sort keys %dupe ) {
		my $self = $class->new( method => $meth, headers => $hdr );
		return $self->with_error_invalid_request( "duplicate parameter: @dupe" );
	}

	while ( my ( $k, $v ) = each %param ) { delete $param{ $k } if '' eq $v }

	my %confidential = map +( $_, 1 ), grep !$visible{ $_ }, keys %param;

	$class->new(
		method       => $meth,
		headers      => $hdr,
		parameters   => \%param,
		confidential => \%confidential,
	);
}

sub new {
	my $class  = shift;
	my $self   = bless { @_ }, $class;
	my $meth   = $self->method or Carp::croak 'missing request method';
	my $params = $self->parameters   ||= {};
	my $conf   = $self->confidential ||= {};
	$self->$_ ||= Net::OAuth2Server::Set->new( $params->{ $_ } ) for $class->set_parameters;
	if ( not grep $meth eq $_, $self->allowed_methods )
		{ return $self->with_error_invalid_request( "method not allowed: $meth" ) }
	if ( my @visible = sort grep exists $params->{ $_ } && !$conf->{ $_ }, $self->required_confidential )
		{ return $self->with_error_invalid_request( "parameter not accepted in query string: @visible" ) }
	if ( my @missing = sort grep !exists $params->{ $_ }, $self->required_parameters )
		{ return $self->with_error_invalid_request( "missing parameter: @missing" ) }
	$self->validated;
}

sub validated { $_[0] }

#######################################################################

sub params { my $p = shift->parameters; @$p{ @_ } }
sub param  { my $p = shift->parameters; $$p{ $_[0] } }
sub param_if_confidential {
	my ( $self, $name ) = ( shift, @_ );
	$self->confidential->{ $name } ? $self->parameters->{ $name } : ();
}

#######################################################################

sub with_error { my $self = shift; $self->error = Net::OAuth2Server::Response->new_error( @_ ); $self }
sub with_error_invalid_token             { shift->with_error( invalid_token             => @_ ) }
sub with_error_invalid_request           { shift->with_error( invalid_request           => @_ ) }
sub with_error_invalid_client            { shift->with_error( invalid_client            => @_ ) }
sub with_error_invalid_grant             { shift->with_error( invalid_grant             => @_ ) }
sub with_error_unauthorized_client       { shift->with_error( unauthorized_client       => @_ ) }
sub with_error_access_denied             { shift->with_error( access_denied             => @_ ) }
sub with_error_unsupported_response_type { shift->with_error( unsupported_response_type => @_ ) }
sub with_error_unsupported_grant_type    { shift->with_error( unsupported_grant_type    => @_ ) }
sub with_error_invalid_scope             { shift->with_error( invalid_scope             => @_ ) }
sub with_error_server_error              { shift->with_error( server_error              => @_ ) }
sub with_error_temporarily_unavailable   { shift->with_error( temporarily_unavailable   => @_ ) }

our $VERSION = '0.001';
