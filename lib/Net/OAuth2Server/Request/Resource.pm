use strict; use warnings;

package Net::OAuth2Server::Request::Resource;
our $VERSION = '0.006';

use parent 'Net::OAuth2Server::Request';

sub allowed_methods       { $_[0]->method } # accept whatever the method is
sub accepted_auth         { 'Bearer' }
sub required_parameters   { 'access_token' }
sub confidential_parameters { 'access_token' }

sub get_grant {
	my ( $self, $grant_maker ) = ( shift, shift );
	return if $self->error;
	$grant_maker->from_bearer_token( $self, $self->param( 'access_token' ), @_ )
		or ( $self->error || $self->set_error_invalid_token, return );
}

1;
