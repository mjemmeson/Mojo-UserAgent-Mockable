use 5.014;

package Mojo::UserAgent::Mockable;

use warnings::register;

use Carp;
use JSON::MaybeXS;
use Mojolicious;
use Mojo::Base 'Mojo::UserAgent';
use Mojo::Util qw/secure_compare/;
use Mojo::UserAgent::Mockable::Serializer;
use Mojo::UserAgent::Mockable::Request::Compare;
use Mojo::JSON;
use Scalar::Util;
use TryCatch;

# ABSTRACT: A Mojo User-Agent that can record and play back requests without Internet connectivity, similar to LWP::UserAgent::Mockable

=head1 SYNOPSIS

    my $ua = Mojo::UserAgent::Mockable->new( mode => 'record', file => '/path/to/file' );
    my $tx = $ua->get($url);

    # Then later...
    my $ua = Mojo::UserAgent::Mockable->new( mode => 'playback', file => '/path/to/file' );
    
    my $tx = $ua->get($url); 
    # This is the same content as above. The saved response is returned, and no HTTP request is
    # sent to the remote host.
    my $reconstituted_content = $tx->res->body;

=attr mode

Mode to operate in.  One of:

=for :list
= passthrough
Operates like L<Mojo::UserAgent> in all respects. No recording or playback happen.
= record
Records all transactions made with this instance to the file specified by L</file>.
= playback
Plays back transactions recorded in the file specified by L</file>
= lwp-ua-mockable
Works like L<LWP::UserAgent::Mockable>. Set the LWP_UA_MOCK environment variable to 'playback', 
'record', or 'passthrough', and the LWP_UA_MOCK_FILE environment variable to the recording file.

=attr file

File to record to / play back from.

=attr unrecognized

What to do on an unexpected request.  One of:

=for :list
= exception
Throw an exception (i.e. die).
= null
Return a response with empty content
= fallback
Process the request as if this instance were in "passthrough" mode and perform the HTTP request normally.

=attr ignore_headers

Request header names to ignore when comparing a request made with this class to a stored request in 
playback mode. Specify 'all' to remove any headers from consideration. By default, the 'Connection',
'Host', 'Content-Length', and 'User-Agent' headers are ignored.

=attr ignore_body

Ignore the request body entirely when comparing a request made with this class to a stored request 
in playback mode. 

=head1 THEORY OF OPERATION

=head2 Recording mode

For the life of a given instance of this class, all transactions made using that instance will be 
serialized and stored in memory.  When the instance goes out of scope, or at any time  L</save> is 
called, the transaction cache will be written to the file specfied by L</file> in JSON format. 
Transactions are stored in the cache in the order they were made.

=head2 Playback mode

When this class is instantiated, the instance will read the transaction cache from the file 
specified by L</file>. When a request is first made using the instance, if the request matches 
that of the first transaction in the cache, the request URL will be rewritten to that of the local 
host, and the response from the first stored transaction will be returned to the caller. Each 
subsequent request will be handled similarly, and requests must be made in the same order as they 
were originally made, i.e. if orignally the request order was A, B, C, with responses A', B', C',
requests in order A, C, B will NOT return responses A', C', B'. Request A will correctly return 
response A', but request C will trigger an error (behavior configurable by the L</unrecognized>
option).

=head3 Request matching

Two requests are considered to be equivalent if they have the same URL (order of query parameters
notwithstanding), the same body content, and the same headers.  You may exclude headers from 
consideration by means of the L</ignore_headers> attribute. You may excluse the request body from
consideration by means of the L</ignore_body> attribute.

=head1 CAVEATS

=head2 Encryption

The playback file generated by this module is unencrypted JSON.  Treat the playback file as if 
its contents were being transmitted over an unsecured channel.

=head2 Local application server

Using this module against a local app, e.g.: 

    my $app = Mojolicious->new;
    ...

    my $ua = Mojo::UserAgent::Mockable->new;
    $ua->server->app($app);

Doesn't work, because in playback mode, requests are served from an internal Mojolicious instance.
So if you blow that away, the thing stops working, natch.  You should instead instantiate 
L<Mojo::Server::Daemon> and connect to the app via the server's URL, like so:

    use Mojo::Server::Daemon;
    use Mojo::IOLoop;

    my $app = Mojolicious->new;
    $app->routes->any( ... );

    my $daemon = Mojo::Server::Daemon->new(
        app => $app, 
        ioloop => Mojo::IOLoop->singleton,
        silent => 1,
    );
    
    my $listen = q{http://127.0.0.1};
    $daemon->listen( [$listen] )->start;
    my $port = Mojo::IOLoop->acceptor( $daemon->acceptors->[0] )->port;
    my $url  = Mojo::URL->new(qq{$listen:$port})->userinfo('joeblow:foobar');
    
    my $output_file = qq{/path/to/file.json};
    
    my $mock = Mojo::UserAgent::Mockable->new(ioloop => Mojo::IOLoop->singleton, mode => 'record', file => $output_file);
    my $tx = $mock->get($url);

=head2 Mojolicious::Lite

You will often see tests written using L<Mojolicious::Lite> like so:

    use Mojolicious::Lite;

    get '/' => sub { ... };

    post '/foo' => sub { ... };

And then, further down:

    my $ua = Mojo::UserAgent->new;

    is( $ua->get('/')->res->text, ..., 'Text OK' );
Or:

    use Test::Mojo;
    my $t = Test::Mojo->new;
    $t->get_ok('/')->status_is(200)->text_is( ... );

And this is all fine. Where it stops being fine is when you have Mojo::UserAgent::Mockable on board:

    use Mojolicious::Lite;

    get '/' => sub { ... };

    post '/foo' => sub { ... };
    
    use Test::Mojo;
    my $t = Test::Mojo->new;
    my $mock = Mojo::UserAgent::Mockable->new( mode => 'playback', file => ... );
    $t->get_ok('/')->status_is(200)->text_is( ... );

Mojolicious::Lite will replace the current UA's internal application server's application instance 
(L<Mojo::UserAgent::Server/app>) with the Mojolicious::Lite application.  This will break the 
playback functionality, as this depends on a custom Mojolicious application internal to the module.
Instead, define your application in a separate package (not necessarily a separate file), like so:

    package MyApp;
    use Mojolicious::Lite;
    get '/' => sub { ... };
    post '/foo' => sub { ... };

    # Actual test application
    package main;

    use Mojo::UserAgent::Mockable;
    use Mojo::Server::Daemon;
    use Mojo::IOLoop;
    use Test::Mojo;

    $app->routes->get('/' => sub { ... });
    $app->routes->post('/foo' => sub { ... });

    my $daemon = Mojo::Server::Daemon->new(
        app    => $app,
        ioloop => Mojo::IOLoop->singleton,
        silent => 1,
    );

    my $listen = q{http://127.0.0.1};
    $daemon->listen( [$listen] )->start;
    my $port = Mojo::IOLoop->acceptor( $daemon->acceptors->[0] )->port;
    my $url  = Mojo::URL->new(qq{$listen:$port})->userinfo('joeblow:foobar');

    my $mock = Mojo::UserAgent::Mockable->new(ioloop => Mojo::IOLoop::singleton, mode => playback, file => ... );
    my $t = Test::Mojo->new;
    $t->ua($mock);
    $mock->get_ok($url->clone->path('/'))->status_is(200)->text_is( ... );

You can also do the following (as seen in t/030_basic_authentication.t):

    use Mojolicious;
    use Mojo::Server::Daemon;
    use Mojo::IOLoop;

    my $app = Mojolicious->new;
    $app->routes->get('/' => sub { ... });
    $app->routes->post('/foo' => sub { ... });

    my $daemon = Mojo::Server::Daemon->new(
        app    => $app,
        ioloop => Mojo::IOLoop->singleton,
        silent => 1,
    );

    my $listen = q{http://127.0.0.1};
    $daemon->listen( [$listen] )->start;
    my $port = Mojo::IOLoop->acceptor( $daemon->acceptors->[0] )->port;
    my $url  = Mojo::URL->new(qq{$listen:$port})->userinfo('joeblow:foobar');

    my $mock = Mojo::UserAgent::Mockable->new(ioloop => Mojo::IOLoop::singleton, mode => playback, file => ... );
    my $t = Test::Mojo->new;
    $t->ua($mock);
    $t->get_ok('/')->status_is(200)->content_is( ... );

=head2 Events

The following transaction level events will not be emitted during playback:

=for :list
=item pre_freeze
=item post_freeze
=item resume

=method save

In record mode, save the transaction cache to the file specified by L</file> for later playback.

=head1 SEE ALSO

=for :list
=item * L<Mojo::UserAgent> 
The class being mocked (but not derided, because the whole Mojo thing is really quite clever)
=item * L<Mojo::Transaction::HTTP> 
Where the magic happens

=head1 CONTRIBUTORS

Steve Wagner C<< <truroot at gmail.com> >>

Joel Berger C<< <joel.a.berger at gmail.com> >>

Dan Book C<< <grinnz at grinnz.com> >>

Stefan Adams  C<< <stefan@borgia.com> >>

Mohammad Anwar C<< mohammad.anwar@yahoo.com >>

Everyone on #mojo on irc.perl.org

=cut

has 'mode' => 'passthrough';
has 'file';
has 'unrecognized' => 'exception';
has '_serializer' => sub { Mojo::UserAgent::Mockable::Serializer->new };
has 'comparator';
has 'ignore_headers' => sub { [] };
has 'ignore_body';
has '_mode';
has '_current_txn';
has '_compare_result';
has '_non_blocking';

# Internal Mojolicious app that handles transaction playback
has '_app' => sub {
    my $self = shift;
    my $app  = Mojolicious->new;
    $app->routes->any(
        '/*any' => { any => '' } => sub {
            my $c  = shift;
            my $tx = $c->tx;

            my $txn = $self->_current_txn;
            if ($txn) {
                $self->cookie_jar->collect($txn);
                $tx->res( $txn->res );
                $tx->res->headers->header( 'X-MUA-Mockable-Regenerated' => 1 );
                $c->rendered( $txn->res->code );
            }
            else {
                for my $header ( keys %{ $tx->req->headers->to_hash } ) {
                    if ( $header =~ /^X-MUA-Mockable/ ) {
                        my $val = $tx->req->headers->header($header);
                        $tx->res->headers->header( $header, $val );
                    }
                }
                $c->render( text => '' );
            }
        },
    );
    $app;
};

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);

    my %comparator_args = (
        ignore_headers => 'all',
        ignore_body    => $self->ignore_body,
    );
    $self->comparator( Mojo::UserAgent::Mockable::Request::Compare->new(%comparator_args) );

    $self->{'_launchpid'} = $$;
    if ($self->mode eq 'lwp-ua-mockable') {
        $self->_mode($ENV{'LWP_UA_MOCK'});
        if ($self->file) {
            croak qq{Do not specify 'file' when 'mode' is set to 'lwp-ua-mockable'. Use the LWP_UA_MOCK_FILE } 
                 . q{environment var instead.};
        }
        $self->file($ENV{'LWP_UA_MOCK_FILE'});
    }
    elsif ($self->mode ne 'record' && $self->mode ne 'playback' && $self->mode ne 'passthrough') {
        croak q{Invalid mode. Must be one of 'lwp-ua-mockable', 'record', 'playback', or 'passthrough'};
    }
    else {
        $self->_mode($self->mode);
    }

    if ($self->_mode ne 'passthrough' && !$self->file) {
        croak qq{Error: You must specify a recording file};
    }

    if ($self->_mode ne 'passthrough') {
        my $mode = lc $self->_mode;
        my $mode_init = qq{_init_$mode}; 
        if (!$self->can($mode_init)) {
            croak qq{Error: unsupported mode "$mode"};
        }
        return $self->$mode_init;
    }

    return $self;
}

sub save {
    my ( $self, $file ) = @_;
    if ( $self->_mode eq 'record' ) {
        $file ||= $self->file;

        my $transactions = $self->{'_transactions'};
        $self->_serializer->store($file, @{$transactions});
    }
    else {
        carp 'save() only works in record mode' if warnings::enabled;
    }
}

sub start {
    my ( $self, $tx, $cb ) = @_;
    if ($cb) {
        $self->_non_blocking(1);
    }
    return $self->SUPER::start( $tx, $cb );
}

sub _init_playback {
    my $self = shift;

    if (! -e $self->file ) {
        my $file = $self->file;
        croak qq{Playback file $file not found};
    }
    $self->{'_transactions'} = [ $self->_serializer->retrieve( $self->file ) ];

    $self->server->app( $self->_app );

    Scalar::Util::weaken($self);
    $self->on(
        start => sub {
            my ( $ua, $tx ) = @_;

            my $port         = $self->_non_blocking ? $self->server->nb_url->port : $self->server->url->port;
            my $recorded_tx  = shift @{ $self->{'_transactions'} };

            if ( $self->comparator->compare( $tx->req, $recorded_tx->req ) ) {
                $self->_current_txn($recorded_tx);
                
                $tx->req->url($tx->req->url->clone);
                $tx->req->url->host('')->scheme('')->port($port);
            }
            else {
                unshift @{$self->{'_transactions'}}, $recorded_tx;

                my $result = $self->comparator->compare_result;
                $self->_current_txn(undef);
                if ( $self->unrecognized eq 'exception' ) {
                    croak qq{Unrecognized request: $result};
                }
                elsif ( $self->unrecognized eq 'null' ) {
                    $tx->req->headers->header( 'X-MUA-Mockable-Request-Recognized'      => 0 );
                    $tx->req->headers->header( 'X-MUA-Mockable-Request-Match-Exception' => $result );
                    $tx->req->url->host('')->scheme('')->port($port);
                }
                elsif ( $self->unrecognized eq 'fallback' ) {
                    $tx->on(
                        finish => sub {
                            my $self = shift;
                            $tx->req->headers->header( 'X-MUA-Mockable-Request-Recognized'      => 0 );
                            $tx->req->headers->header( 'X-MUA-Mockable-Request-Match-Exception' => $result );
                        }
                    );
                }
            }
        }
    );

    return $self;
}


sub _init_record {
    my $self = shift;

    Scalar::Util::weaken($self);
    $self->on(
        start => sub {
            my $tx = $_[1];

            $tx->once(
                finish => sub {
                    my $tx  = shift;
                    push @{ $self->{'_transactions'} }, $tx;
                }
            );
        },
    );

    return $self;
}

sub _load_transactions {
    my ($self) = @_;

    my @transactions = $self->_serializer->retrieve($self->file);

    return \@transactions;
}

# In record mode, write out the recorded file 
 sub DESTROY { 
     my $self = shift;
 
     if ($self->_mode eq 'record') {
         my $dir = (File::Spec->splitpath($self->file))[1];
         unless($dir){
	   warnings::warn qq{Using current working directory} if warnings::enabled;
	   $dir = '.';
	 }
         warn qq{"$dir" does not exist} unless -e $dir;
         if ( ! -e $dir && warnings::enabled) {
             carp qq{Cannot write output file: directory "$dir" does not exist};
         }
         $self->save($self->file);
     }
 }
1;
