package CPAN::Testers::DB::Command::import;
our $VERSION = '0.001';

=head1 SYNOPSIS

  script/cpantesters-db import --manifest <#>

=head1 DESCRIPTION

This takes a manifest file index (created by L<CPAN::Testers::Collector::Command::manifest>)
and imports the data into the database.

=cut

use Mojo::Base 'Mojolicious::Command', -signatures, -async_await;
use Getopt::Long qw( GetOptionsFromArray :config pass_through );
use JSON::XS qw( decode_json encode_json );
use Log::Any qw( $LOG );
use Log::Any::Adapter qw( Stderr );
use MetaCPAN::Client;

my $manifest_prefix = 'manifest.';

sub run( $self, @args ) {
  my %opt = (
    manifest => 0,
    jobs => 20,
  );

  GetOptionsFromArray(\@args, \%opt, 'manifest=i', 'jobs=i') or pod2usage(1);

  $LOG->info('Starting ' . __PACKAGE__, {%opt} );
  my $app = $self->app;

  # Download the manifest file we've been directed to use
  my $manifest_name = $manifest_prefix . $opt{manifest};
  my $manifest_url = sprintf 'https://collector.cpantesters.org/v1/report/%s', $manifest_name;
  my $tx = $app->ua->get($manifest_url);
  my $manifest_data = $tx->res->body;
  my @uuids = split /\n/, $manifest_data;
  $LOG->info('Got manifest', {name => $manifest_name, size => scalar @uuids});

  # Loop over the UUIDs
  my $started = 0;
  for my $uuid ( @uuids ) {
    if (++$started % 1_000 == 0) {
      $LOG->info('Processed', {started => $started, total => scalar @uuids, pct => sprintf("%02f",($started/@uuids)*100), });
    }

    local $LOG->context->{uuid} = $uuid;
    local $SIG{__WARN__} = sub(@args) {
      chomp for @args;
      $LOG->warn(@args);
    };

    # Fetch the report
    my $report_url = sprintf 'https://collector.cpantesters.org/v1/report/%s', $uuid;
    my $tx = $app->ua->get($report_url);
    my $report = $tx->res->json;
    $LOG->info('Got report', { uuid => $uuid, dist => {$report->{distribution}->%{qw(name version)}}, grade => $report->{result}{grade} });
    my $pg = $app->pg;

    # Write the necessary records to the database
    # 1. lang, author, tester, platform
    my $lang_p = get_id($pg->db, lang => {
      name => $report->{environment}{language}{name},
    });
    my $tester_p = get_id($pg->db, tester => {
      $report->{reporter}->%{qw(name email)},
    });
    my $platform_p = get_id($pg->db, platform => {
      osname => $report->{environment}{system}{osname},
      osvers => $report->{environment}{system}{osversion},
      arch => $report->{environment}{language}{archname},
    });

    # 2. lang_vers
    my $lang_vers_p = $lang_p->then(sub($lang_id) {
      get_id($pg->db, lang_vers => {
        lang_id => $lang_id,
        version => $report->{environment}{language}{version},
        build => $report->{environment}{language}{build},
      });
    });

    # 2. dist 3. dist_vers
    my $dist_vers_p = $lang_p->then(sub($lang_id) {
      insert_dist_vers($pg->db, $lang_id, $report->{distribution});
    });

    # 4. report
    my $report_p = Mojo::Promise->all($tester_p, $platform_p, $lang_vers_p, $dist_vers_p)->then(
      sub ($tester, $platform, $lang_vers, $dist_vers) {
        get_id( $pg->db, report => {
            report_uuid => $report->{id} // $uuid,
            created => $report->{created},
            tester_id => $tester->[0],
            platform_id => $platform->[0],
            lang_vers_id => $lang_vers->[0],
            dist_vers_id => $dist_vers->[0],
            grade => lc $report->{result}{grade},
          },
        );
      },
    );

    # 5. report_deps
    Mojo::Promise->all($report_p, $lang_p)->then(
      async sub($report_p, $lang_p) {
        my $report_id = $report_p->[0];
        my $lang_id = $lang_p->[0];
        my @promises;

        # Distribution
        for my $dep (@{ $report->{distribution}{prerequisites} }) {
          # `perl` is actually a distribution, though...
          if ($dep->{name} eq 'perl') {
            # XXX
            next;
          }

          await insert_pkg_vers($pg->db, $lang_id, {
              name => $dep->{name},
              version => $dep->{have},
            })->then(sub($pkg_id, $dist_vers_id) {
              return unless $pkg_id && $dist_vers_id;
              $pg->db->insert_p( report_dep => {
                report_id => $report_id,
                dist_vers_id => $dist_vers_id,
                pkg_id => $pkg_id,
                phase => $dep->{phase},
              }, {on_conflict => undef});
            });
        }

        # Toolchain
        for my $pkg_name (keys $report->{environment}{toolchain}->%*) {
          my $pkg_version = $report->{environment}{toolchain}{$pkg_name};
          await insert_pkg_vers($pg->db, $lang_id, {
              name => $pkg_name,
              version => $pkg_version,
            })->then(sub($pkg_id, $dist_vers_id) {
              return unless $pkg_id && $dist_vers_id;
              $pg->db->insert_p( report_dep => {
                report_id => $report_id,
                dist_vers_id => $dist_vers_id,
                pkg_id => $pkg_id,
                phase => 'toolchain',
              }, {on_conflict => undef});
            });
        }
      },
    )->wait;

  }

  $LOG->info("Waiting for children to finish");
}

async sub get_id( $db, $table, $data ) {
  # First, try to fetch the ID from the data
  my $res = await $db->select_p($table, ["${table}_id"], $data);
  if ($res->rows) {
    return $res->array->[0];
  }
  # ID wasn't found, so try to insert. Since we may have concurrency,
  # we also try to prevent conflicts.
  $res = await $db->insert_p($table, $data, {on_conflict => undef, returning => ["${table}_id"]});
  if ($res->rows) {
    return $res->array->[0];
  }
  # In the case of a conflict, no ID will be returned. But, now
  # we can fetch the ID...
  return await __SUB__->($db, $table, $data);
}

async sub insert_dist_vers($db, $lang_id, $dist) {
  state $mc = MetaCPAN::Client->new;

  my $dist_id = await get_id($db,
    dist => {
      name => $dist->{name},
      lang_id => $lang_id,
    },
  );
  my $dist_vers_id = await get_id( $db, 
    dist_vers => {
      dist_id => $dist_id,
      version => $dist->{version},
      # path and author_id will be filled in below
    },
  );

  # Fill in the dist_vers_pkgs if we don't have any
  my $dist_vers_pkgs = await $db->select_p(dist_vers_pkg => ['*'], {dist_vers_id => $dist_vers_id});
  if (!$dist_vers_pkgs->rows) {
    my $dist_search = {
      all => [
        { distribution => $dist->{name} },
        { version => $dist->{version} },
      ],
    };
    $LOG->debug('Looking up release on MetaCPAN', {$dist->%{qw(name version)}});
    my $release = $mc->release($dist_search)->next;

    if ($release) {
      # Assume that we also need to update the author of this release.
      my $author_id = await get_id($db, author => {
        username => $release->author,
        domain => 'pause.perl.org',
      });
      await $db->update_p(
        dist_vers => {
          author_id => $author_id,
          path => $release->archive,
        },
        {
          dist_vers_id => $dist_vers_id,
        },
      );

      for my $pkg ($release->provides->@*) {
        $LOG->info('Inserting package', { pkg => $pkg, dist => $dist->{name}, vers => $dist->{version} });
        my $pkg_id = await get_id( $db, pkg => {
          lang_id => $lang_id,
          name => $pkg,
        });
        await $db->insert_p(
          dist_vers_pkg => {
            dist_vers_id => $dist_vers_id,
            pkg_id => $pkg_id,
          },
          { on_conflict => undef },
        );
      }
    }
    else {
      $LOG->warn('Could not find release', {$dist->%{qw(name version)}});
    }
  }

  return $dist_vers_id;
}

async sub insert_pkg_vers($db, $lang_id, $pkg) {
  # This is very similar to insert_dist_vers, except we need to look up the
  # distribution this package belongs to. From there, we can defer to
  # insert_dist_vers which will then fill in all the packages provided by the
  # distribution.
  # FIXME: If the `dist` for this package is exactly `perl`, we can't look up
  # the package's version. We have to instead look up in Module::CoreList
  state $mc = MetaCPAN::Client->new;
  state %not_found = ();
  my $pkg_id = await get_id( $db, pkg => {
    lang_id => $lang_id,
    name => $pkg->{name},
  });
  my $dist_vers_pkgs = await $db->select_p(dist_vers_pkg => ['*'], {pkg_id => $pkg_id});
  my $dist_vers_id;
  if ($dist_vers_pkgs->rows) {
    $dist_vers_id = $dist_vers_pkgs->hash->{dist_vers_id};
  }
  elsif (!$not_found{$pkg->{name}}{$pkg->{version}}++) {
    $LOG->info('Fetching module from MetaCPAN', $pkg);
    my $module = $mc->module({
      all => [
        { module => $pkg->{name} },
        { version => $pkg->{version} },
      ],
    })->next;
    if ($module) {
      $LOG->info('Got dist for module', {dist => $module->distribution});
      $dist_vers_id = await insert_dist_vers($db, $lang_id, {
        name => $module->distribution,
        version => $pkg->{version},
      });
    }
    else {
      $LOG->info('Fetching package from MetaCPAN', $pkg);
      my $package = $mc->package({
        all => [
          { module_name => $pkg->{name} },
        ],
      })->next;
      if ($package) {
        $LOG->info('Got dist for module', {dist => $package->distribution});
        $dist_vers_id = await insert_dist_vers($db, $lang_id, {
          name => $package->distribution,
          version => $pkg->{version},
        });
      }
      else {
        # Try one last time, this time using the package as the "dist"
        $LOG->debug('Looking up dist from module', {$pkg->%{qw(name version)}});
        my $dist = $mc->distribution({
          all => [
            { name => $pkg->{name} },
            { version => $pkg->{version} },
          ],
        })->next;
        if ($dist) {
          $LOG->info('Got dist for module', {dist => $dist->name});
          $dist_vers_id = await insert_dist_vers($db, $lang_id, {
            name => $dist->name,
            version => $pkg->{version},
          });
        }
        else {
          $LOG->warn('Could not find dist for module', $pkg);
        }
      }
    }
  }
  return $pkg_id, $dist_vers_id;
}

1;
