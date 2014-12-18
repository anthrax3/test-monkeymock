package Test::MonkeyMock;

use strict;
use warnings;

require Carp;
use Storable;

our $VERSION = '0.07';

my $registry      = {};
my $magic_counter = 0;

sub new {
    my $class = shift;
    $class = ref $class if ref $class;
    my ($instance) = @_;

    my $new_package;

    if ($instance) {
        $new_package =
            __PACKAGE__ . '::'
          . ref($instance)
          . '::__instance__'
          . ($magic_counter++);

        no strict 'refs';
        @{$new_package . '::ISA'} = (ref($instance));
    }
    else {
        $instance = {};
        $new_package = __PACKAGE__ . '::' . ($magic_counter++);

        no strict 'refs';
        @{$new_package . '::ISA'} = __PACKAGE__;
    }

    no strict 'refs';
    for my $method (
        qw/
        mock
        mocked_called
        mocked_call_args
        mocked_call_stack
        mocked_return_args
        mocked_return_stack
        /
      )
    {
        *{$new_package . '::' . $method} = sub { goto &$method };
    }

    bless $instance, $new_package;

    return $instance;
}

sub mock {
    my $self = shift;
    my ($method, $code, %options) = @_;

    if (ref($self) =~ m/__instance__/) {
        Carp::croak("Unknown method '$method'")
          unless my $orig_method = $self->can($method);

        if (exists $registry->{ref($self)}->{'mocks'}->{$method}) {
            push @{$registry->{ref($self)}->{'mocks'}->{$method}},
              {code => $code, orig_code => $orig_method};
            return;
        }

        my $ref_self = ref($self);
        my $package  = __PACKAGE__;
        $ref_self =~ s/^${package}::.*::__instance__\d+//;

        my $new_package =
          __PACKAGE__ . '::' . $ref_self . '::__instance__' . $magic_counter++;

        $registry->{$new_package} =
          Storable::dclone($registry->{ref($self)} || {});

        my $mocks = $registry->{$new_package}->{'mocks'} ||= {};
        $mocks->{$method} =
          [{code => $code, orig_code => $orig_method, options => \%options}];

        no strict 'refs';
        @{$new_package . '::ISA'} = ref($self);
        *{$new_package . '::' . $method} = sub {
            _dispatch($new_package, $method, @_);
        };

        bless $self, $new_package;
    }
    else {
        my $mocks = $registry->{ref($self)}->{'mocks'} ||= {};
        push @{$mocks->{$method}},
          {
            code    => $code,
            options => \%options
          };
    }

    return $self;
}

sub mocked_called {
    my $self = shift;
    my ($method) = @_;

    my $mocks = $registry->{ref($self)}->{'mocks'} ||= {};
    my $calls = $registry->{ref($self)}->{'calls'} ||= {};

    if (ref($self) =~ m/__instance__/) {
        Carp::croak("Unknown method '$method'")
          unless $self->can($method);
    }
    else {
        Carp::croak("Unmocked method '$method'")
          unless exists $mocks->{$method};
    }

    return $calls->{$method}->{called} || 0;
}

sub mocked_call_args {
    my $self = shift;
    my ($method, $frame) = @_;

    $frame ||= 0;

    my $stack = $self->mocked_call_stack($method);

    Carp::croak("Unknown frame '$frame'")
      unless @$stack > $frame;

    return @{$stack->[$frame]};
}

sub mocked_call_stack {
    my $self = shift;
    my ($method) = @_;

    Carp::croak("Method is required") unless $method;

    my $calls = $registry->{ref($self)}->{'calls'} ||= {};
    my $mocks = $registry->{ref($self)}->{'mocks'} ||= {};

    if (ref($self) =~ m/__instance__/) {
        Carp::croak("Unknown method '$method'")
          unless $self->can($method);
    }
    else {
        Carp::croak("Unmocked method '$method'")
          unless exists $mocks->{$method};
    }

    Carp::croak("Method '$method' was not called")
      unless exists $calls->{$method};

    return $calls->{$method}->{stack};
}

sub mocked_return_args {
    my $self = shift;
    my ($method, $frame) = @_;

    $frame ||= 0;

    my $stack = $self->mocked_return_stack($method);

    Carp::croak("Unknown frame '$frame'")
      unless @$stack > $frame;

    return @{$stack->[$frame]};
}

sub mocked_return_stack {
    my $self = shift;
    my ($method) = @_;

    Carp::croak("Method is required") unless $method;

    my $returns = $registry->{ref($self)}->{'returns'} ||= {};
    my $mocks   = $registry->{ref($self)}->{'mocks'}   ||= {};

    if (ref($self) =~ m/__instance__/) {
        Carp::croak("Unknown method '$method'")
          unless $self->can($method);
    }
    else {
        Carp::croak("Unmocked method '$method'")
          unless exists $mocks->{$method};
    }

    Carp::croak("Method '$method' was not called")
      unless exists $returns->{$method};

    return $returns->{$method}->{stack};
}

sub can {
    my $self = shift;
    my ($method) = @_;

    if (ref($self) =~ m/__instance__/) {
        return $self->can($method);
    }
    else {
        my $mocks = $registry->{ref($self)}->{'mocks'} ||= {};
        return $mocks->{$method}->[0]->{code};
    }
}

our $AUTOLOAD;

sub AUTOLOAD {
    my $self = shift;

    my ($method) = (split /::/, $AUTOLOAD)[-1];

    return if $method =~ /^[A-Z]+$/;

    return _dispatch(ref($self), $method, $self, @_);
}

sub _dispatch {
    my ($ref_self, $method, @args) = @_;

    my $calls   = $registry->{$ref_self}->{'calls'}   ||= {};
    my $returns = $registry->{$ref_self}->{'returns'} ||= {};
    my $mocks   = $registry->{$ref_self}->{'mocks'}   ||= {};

    Carp::croak("Unmocked method '$method'")
      if !exists $mocks->{$method};

    foreach my $mock (@{$mocks->{$method}}) {
        if (my $options = $mock->{options}) {
            if (my $when = $options->{when}) {
                next unless $when->(@args);
            }
        }

        $calls->{$method}->{called}++;

        push @{$calls->{$method}->{stack}}, [@args[1 .. $#args]];

        my @result;

        if (my $code = $mock->{code}) {
            @result = $code->(@args);
        }
        elsif (my $orig_code = $mock->{orig_code}) {
            @result = $orig_code->(@args);
        }
        else {
            Carp::croak("Unmocked method '$method'");
        }

        push @{$returns->{$method}->{stack}}, [@result];

        return wantarray ? @result : $result[0];
    }
}

1;
__END__

=pod

=head1 NAME

Test::MonkeyMock - Usable mock class

=head1 SYNOPSIS

    # Create a new mock object
    my $mock = Test::MonkeyMock->new;
    $mock->mock(foo => sub {'bar'});
    $mock->foo;

    # Mock existing object
    my $mock = Test::MonkeyMock->new(MyObject->new());
    $mock->mock(foo => sub {'bar'});
    $mock->foo;

    # Check how many times the method was called
    my $count = $mock->mocked_called('foo');

    # Check what arguments were passed on the first call
    my @args = $mock->mocked_call_args('foo');

    # Check what arguments were passed on the second call
    my @args = $mock->mocked_call_args('foo', 1);

    # Get all the stack
    my $call_stack = $mock->mocked_call_stack('foo');

=head1 DESCRIPTION

Why? I used and still use L<Test::MockObject> and L<Test::MockObject::Extends>
a lot but sometimes it behaves very strangely introducing hard to find global
bugs in the test code, which is very painful, since the test suite should have
as least bugs as possible. L<Test::MonkeyMock> is somewhat a subset of
L<Test::MockObject> but without side effects.

L<Test::MonkeyMock> is also very strict. When mocking a new object:

=over

=item * throw when using C<mocked_called> on unmocked method

=item * throw when using C<mocked_call_args> on unmocked method

=back

When mocking an existing object:

=over

=item * throw when using C<mock> on unknown method

=item * throw when using C<mocked_called> on unknown method

=item * throw when using C<mocked_call_args> on unknown method

=back

=head1 AUTHOR

Viacheslav Tykhanovskyi, C<vti@cpan.org>.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012-2013, Viacheslav Tykhanovskyi

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=cut
