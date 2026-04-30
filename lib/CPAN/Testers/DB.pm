package CPAN::Testers::DB;
our $VERSION = '0.001';
# ABSTRACT: Modern OLAP database for CPAN Testers database

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 SEE ALSO

=cut

use v5.40;
use Mojo::Base 'Mojolicious', -signatures, -async_await;
use Log::Any::Adapter 'Multiplex' =>
  # Set up Log::Any to log to OpenTelemetry and Stderr so we can still
  # see the local logs.
  adapters => {
    'OpenTelemetry' => [],
    'Stderr' => [
      log_level => $ENV{LOG_LEVEL} || $ENV{MOJO_LOG_LEVEL} || "debug",
    ],
  };
use Log::Any qw( $LOG );
use Mojo::Pg;

has pg => sub($self) {
  # Use a PostgreSQL connection string for configuration
  my $pg = Mojo::Pg->new('postgresql://cpantesters@/cpantesters');
  $pg->migrations->name('cpantesters')->from_data(__PACKAGE__, 'migrations.pg.sql')->migrate;

  # Use migrations to drop and recreate the entire database, for development
  # purposes.
  #$pg->migrations->migrate(0)->migrate;

  return $pg;
};

sub startup( $self ) {
  # Remove Mojo::Log from STDERR so that we don't double-log
  $self->log(Mojo::Log->new(handle => undef));
  # Forward Mojo::Log logs to the Log::Any logger, so that from there
  # they will be forwarded to OpenTelemetry.
  # Modules should prefer to log with Log::Any because it supports
  # structured logging.
  $self->log->on( message => sub ( $, $level, @lines ) {
    $LOG->$level(@lines);
  });

  push @{$self->commands->namespaces}, 'CPAN::Testers::DB::Command';

}

1;
__DATA__

@@ migrations.pg.sql

-- 1 up

CREATE TABLE IF NOT EXISTS lang (
  lang_id SMALLSERIAL PRIMARY KEY,
  name VARCHAR UNIQUE
);

CREATE TABLE IF NOT EXISTS author (
  author_id SERIAL PRIMARY KEY,
  domain VARCHAR,
  username VARCHAR,
  UNIQUE (domain, username)
);

CREATE TABLE IF NOT EXISTS dist (
  dist_id BIGSERIAL PRIMARY KEY,
  name VARCHAR,
  lang_id SMALLINT REFERENCES lang (lang_id),
  UNIQUE (name, lang_id)
);

CREATE TABLE IF NOT EXISTS tester (
  tester_id SERIAL PRIMARY KEY,
  tester_uuid UUID,
  name VARCHAR,
  email VARCHAR
);

CREATE TABLE IF NOT EXISTS platform (
  platform_id BIGSERIAL PRIMARY KEY,
  osname VARCHAR,
  osvers VARCHAR,
  arch VARCHAR,
  UNIQUE (osname, osvers, arch)
);

CREATE TABLE IF NOT EXISTS lang_vers (
  lang_vers_id SERIAL PRIMARY KEY,
  lang_id SMALLINT REFERENCES lang (lang_id),
  version VARCHAR NOT NULL,
  build VARCHAR,
  released TIMESTAMP,
  UNIQUE (lang_id, version, build)
);

CREATE TABLE IF NOT EXISTS dist_vers (
  dist_vers_id BIGSERIAL PRIMARY KEY,
  dist_id BIGINT REFERENCES dist (dist_id),
  author_id INT REFERENCES author (author_id),
  version VARCHAR,
  path VARCHAR,
  released TIMESTAMP,
  UNIQUE (dist_id, version)
);

CREATE TABLE IF NOT EXISTS report (
  report_id BIGSERIAL PRIMARY KEY,
  report_uuid UUID UNIQUE,
  created TIMESTAMP,
  tester_id INT REFERENCES tester (tester_id),
  dist_vers_id BIGINT REFERENCES dist_vers (dist_vers_id),
  lang_vers_id INT REFERENCES lang_vers (lang_vers_id),
  platform_id BIGINT REFERENCES platform (platform_id),
  grade VARCHAR
);

-- 1 down
DROP TABLE IF EXISTS report;
DROP TABLE IF EXISTS dist_vers;
DROP TABLE IF EXISTS lang_vers;
DROP TABLE IF EXISTS platform;
DROP TABLE IF EXISTS tester;
DROP TABLE IF EXISTS dist;
DROP TABLE IF EXISTS author;
DROP TABLE IF EXISTS lang;

-- 2 up
CREATE TABLE IF NOT EXISTS pkg (
  pkg_id BIGSERIAL PRIMARY KEY,
  lang_id SMALLINT REFERENCES lang (lang_id),
  name VARCHAR,
  UNIQUE (lang_id, name)
);

CREATE TABLE IF NOT EXISTS dist_vers_pkg (
  dist_vers_id BIGINT NOT NULL REFERENCES dist_vers (dist_vers_id),
  pkg_id BIGINT NOT NULL REFERENCES pkg (pkg_id),
  PRIMARY KEY(dist_vers_id, pkg_id)
);

CREATE TABLE IF NOT EXISTS report_dep (
  report_id BIGINT NOT NULL REFERENCES report (report_id) ON DELETE CASCADE,
  dist_vers_id BIGINT NOT NULL REFERENCES dist_vers (dist_vers_id) ON DELETE CASCADE,
  pkg_id BIGINT NOT NULL REFERENCES pkg (pkg_id),
  phase VARCHAR,
  UNIQUE (report_id, dist_vers_id, pkg_id, phase)
);

-- 2 down
DROP TABLE IF EXISTS report_dep;
DROP TABLE IF EXISTS dist_vers_pkg;
DROP TABLE IF EXISTS pkg;
