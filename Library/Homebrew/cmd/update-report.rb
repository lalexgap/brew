# typed: false
# frozen_string_literal: true

require "formula_versions"
require "migrator"
require "formulary"
require "descriptions"
require "cleanup"
require "description_cache_store"
require "cli/parser"
require "settings"
require "linuxbrew-core-migration"

module Homebrew
  extend T::Sig

  module_function

  def update_preinstall_header(args:)
    @update_preinstall_header ||= begin
      ohai "Auto-updated Homebrew!" if args.preinstall?
      true
    end
  end

  sig { returns(CLI::Parser) }
  def update_report_args
    Homebrew::CLI::Parser.new do
      description <<~EOS
        The Ruby implementation of `brew update`. Never called manually.
      EOS
      switch "--preinstall",
             description: "Run in 'auto-update' mode (faster, less output)."
      switch "-f", "--force",
             description: "Treat installed and updated formulae as if they are from "\
                          "the same taps and migrate them anyway."

      hide_from_man_page!
    end
  end

  def update_report
    return output_update_report if $stdout.tty?

    redirect_stdout($stderr) do
      output_update_report
    end
  end

  def output_update_report
    args = update_report_args.parse

    # Run `brew update` (again) if we've got a linuxbrew-core CoreTap
    if CoreTap.instance.installed? && CoreTap.instance.linuxbrew_core? &&
       ENV["HOMEBREW_LINUXBREW_CORE_MIGRATION"].blank?
      ohai "Re-running `brew update` for linuxbrew-core migration"

      if ENV["HOMEBREW_CORE_DEFAULT_GIT_REMOTE"] != ENV["HOMEBREW_CORE_GIT_REMOTE"]
        opoo <<~EOS
          HOMEBREW_CORE_GIT_REMOTE was set: #{ENV["HOMEBREW_CORE_GIT_REMOTE"]}.
          It has been unset for the migration.
          You may need to change this from a linuxbrew-core mirror to a homebrew-core one.

        EOS
      end
      ENV.delete("HOMEBREW_CORE_GIT_REMOTE")

      if ENV["HOMEBREW_BOTTLE_DEFAULT_DOMAIN"] != ENV["HOMEBREW_BOTTLE_DOMAIN"]
        opoo <<~EOS
          HOMEBREW_BOTTLE_DOMAIN was set: #{ENV["HOMEBREW_BOTTLE_DOMAIN"]}.
          It has been unset for the migration.
          You may need to change this from a Linuxbrew package mirror to a Homebrew one.

        EOS
      end
      ENV.delete("HOMEBREW_BOTTLE_DOMAIN")

      ENV["HOMEBREW_LINUXBREW_CORE_MIGRATION"] = "1"
      FileUtils.rm_f HOMEBREW_LOCKS/"update"

      update_args = []
      update_args << "--preinstall" if args.preinstall?
      update_args << "--force" if args.force?
      exec HOMEBREW_BREW_FILE, "update", *update_args
    end

    if !Utils::Analytics.messages_displayed? &&
       !Utils::Analytics.disabled? &&
       !Utils::Analytics.no_message_output?

      ENV["HOMEBREW_NO_ANALYTICS_THIS_RUN"] = "1"
      # Use the shell's audible bell.
      print "\a"

      # Use an extra newline and bold to avoid this being missed.
      ohai "Homebrew has enabled anonymous aggregate formula and cask analytics."
      puts <<~EOS
        #{Tty.bold}Read the analytics documentation (and how to opt-out) here:
          #{Formatter.url("https://docs.brew.sh/Analytics")}#{Tty.reset}
        No analytics have been recorded yet (nor will be during this `brew` run).

      EOS

      # Consider the messages possibly missed if not a TTY.
      Utils::Analytics.messages_displayed! if $stdout.tty?
    end

    if Settings.read("donationmessage") != "true" && !args.quiet?
      ohai "Homebrew is run entirely by unpaid volunteers. Please consider donating:"
      puts "  #{Formatter.url("https://github.com/Homebrew/brew#donations")}\n"

      # Consider the message possibly missed if not a TTY.
      Settings.write "donationmessage", true if $stdout.tty?
    end

    install_core_tap_if_necessary

    updated = false
    new_repository_version = nil

    initial_revision = ENV["HOMEBREW_UPDATE_BEFORE"].to_s
    current_revision = ENV["HOMEBREW_UPDATE_AFTER"].to_s
    odie "update-report should not be called directly!" if initial_revision.empty? || current_revision.empty?

    if initial_revision != current_revision
      update_preinstall_header args: args
      puts "Updated Homebrew from #{shorten_revision(initial_revision)} to #{shorten_revision(current_revision)}."
      updated = true

      old_tag = Settings.read "latesttag"

      new_tag = Utils.popen_read(
        "git", "-C", HOMEBREW_REPOSITORY, "tag", "--list", "--sort=-version:refname", "*.*"
      ).lines.first.chomp

      new_repository_version = new_tag if new_tag != old_tag
    end

    Homebrew.failed = true if ENV["HOMEBREW_UPDATE_FAILED"]
    return if ENV["HOMEBREW_DISABLE_LOAD_FORMULA"]

    hub = ReporterHub.new

    updated_taps = []
    Tap.each do |tap|
      next unless tap.git?
      next if (tap.core_tap? || tap == "homebrew/cask") && Homebrew::EnvConfig.install_from_api? && args.preinstall?

      if ENV["HOMEBREW_MIGRATE_LINUXBREW_FORMULAE"].present? && tap.core_tap? &&
         Settings.read("linuxbrewmigrated") != "true"
        ohai "Migrating formulae from linuxbrew-core to homebrew-core"

        LINUXBREW_CORE_MIGRATION_LIST.each do |name|
          begin
            formula = Formula[name]
          rescue FormulaUnavailableError
            next
          end
          next unless formula.any_version_installed?

          keg = formula.installed_kegs.last
          tab = Tab.for_keg(keg)
          # force a `brew upgrade` from the linuxbrew-core version to the homebrew-core version (even if lower)
          tab.source["versions"]["version_scheme"] = -1
          tab.write
        end

        Settings.write "linuxbrewmigrated", true
      end

      begin
        reporter = Reporter.new(tap)
      rescue Reporter::ReporterRevisionUnsetError => e
        onoe "#{e.message}\n#{e.backtrace.join "\n"}" if Homebrew::EnvConfig.developer?
        next
      end
      if reporter.updated?
        updated_taps << tap.name
        hub.add(reporter, preinstall: args.preinstall?)
      end
    end

    unless updated_taps.empty?
      update_preinstall_header args: args
      puts "Updated #{updated_taps.count} #{"tap".pluralize(updated_taps.count)} (#{updated_taps.to_sentence})."
      updated = true
    end

    if updated
      if hub.empty?
        puts "No changes to formulae." unless args.quiet?
      else
        hub.dump(updated_formula_report: !args.preinstall?) unless args.quiet?
        hub.reporters.each(&:migrate_tap_migration)
        hub.reporters.each { |r| r.migrate_formula_rename(force: args.force?, verbose: args.verbose?) }
        CacheStoreDatabase.use(:descriptions) do |db|
          DescriptionCacheStore.new(db)
                               .update_from_report!(hub)
        end

        if !args.preinstall? && !args.quiet?
          outdated_formulae = Formula.installed.count(&:outdated?)
          outdated_casks = Cask::Caskroom.casks.count(&:outdated?)
          update_pronoun = if (outdated_formulae + outdated_casks) == 1
            "it"
          else
            "them"
          end
          msg = ""
          if outdated_formulae.positive?
            msg += "#{Tty.bold}#{outdated_formulae}#{Tty.reset} outdated #{"formula".pluralize(outdated_formulae)}"
          end
          if outdated_casks.positive?
            msg += " and " if msg.present?
            msg += "#{Tty.bold}#{outdated_casks}#{Tty.reset} outdated #{"cask".pluralize(outdated_casks)}"
          end
          if msg.present?
            puts
            puts <<~EOS
              You have #{msg} installed.
              You can upgrade #{update_pronoun} with #{Tty.bold}brew upgrade#{Tty.reset}
              or list #{update_pronoun} with #{Tty.bold}brew outdated#{Tty.reset}.
            EOS
          end
        end
      end
      puts if args.preinstall?
    elsif !args.preinstall? && !ENV["HOMEBREW_UPDATE_FAILED"] && !ENV["HOMEBREW_MIGRATE_LINUXBREW_FORMULAE"]
      puts "Already up-to-date." unless args.quiet?
    end

    Commands.rebuild_commands_completion_list
    link_completions_manpages_and_docs
    Tap.each(&:link_completions_and_manpages)

    failed_fetch_dirs = ENV["HOMEBREW_MISSING_REMOTE_REF_DIRS"]&.split("\n")
    if failed_fetch_dirs.present?
      failed_fetch_taps = failed_fetch_dirs.map { |dir| Tap.from_path(dir) }

      ofail <<~EOS
        Some taps failed to update!
        The following taps can not read their remote branches:
          #{failed_fetch_taps.join("\n  ")}
        This is happening because the remote branch was renamed or deleted.
        Reset taps to point to the correct remote branches by running `brew tap --repair`
      EOS
    end

    return if new_repository_version.blank?

    puts
    ohai "Homebrew was updated to version #{new_repository_version}"
    if new_repository_version.split(".").last == "0"
      Settings.write "latesttag", new_repository_version
      puts <<~EOS
        More detailed release notes are available on the Homebrew Blog:
          #{Formatter.url("https://brew.sh/blog/#{new_repository_version}")}
      EOS
    elsif !args.quiet?
      Settings.write "latesttag", new_repository_version
      puts <<~EOS
        The changelog can be found at:
          #{Formatter.url("https://github.com/Homebrew/brew/releases/tag/#{new_repository_version}")}
      EOS
    end
  end

  def shorten_revision(revision)
    Utils.popen_read("git", "-C", HOMEBREW_REPOSITORY, "rev-parse", "--short", revision).chomp
  end

  def install_core_tap_if_necessary
    return if ENV["HOMEBREW_UPDATE_TEST"]
    return if Homebrew::EnvConfig.install_from_api?

    core_tap = CoreTap.instance
    return if core_tap.installed?

    CoreTap.ensure_installed!
    revision = core_tap.git_head
    ENV["HOMEBREW_UPDATE_BEFORE_HOMEBREW_HOMEBREW_CORE"] = revision
    ENV["HOMEBREW_UPDATE_AFTER_HOMEBREW_HOMEBREW_CORE"] = revision
  end

  def link_completions_manpages_and_docs(repository = HOMEBREW_REPOSITORY)
    command = "brew update"
    Utils::Link.link_completions(repository, command)
    Utils::Link.link_manpages(repository, command)
    Utils::Link.link_docs(repository, command)
  rescue => e
    ofail <<~EOS
      Failed to link all completions, docs and manpages:
        #{e}
    EOS
  end
end

class Reporter
  class ReporterRevisionUnsetError < RuntimeError
    def initialize(var_name)
      super "#{var_name} is unset!"
    end
  end

  attr_reader :tap, :initial_revision, :current_revision

  def initialize(tap)
    @tap = tap

    initial_revision_var = "HOMEBREW_UPDATE_BEFORE#{tap.repo_var}"
    @initial_revision = ENV[initial_revision_var].to_s
    raise ReporterRevisionUnsetError, initial_revision_var if @initial_revision.empty?

    current_revision_var = "HOMEBREW_UPDATE_AFTER#{tap.repo_var}"
    @current_revision = ENV[current_revision_var].to_s
    raise ReporterRevisionUnsetError, current_revision_var if @current_revision.empty?
  end

  def report(preinstall: false)
    return @report if @report

    @report = Hash.new { |h, k| h[k] = [] }
    return @report unless updated?

    diff.each_line do |line|
      status, *paths = line.split
      src = Pathname.new paths.first
      dst = Pathname.new paths.last

      next unless dst.extname == ".rb"

      if paths.any? { |p| tap.cask_file?(p) }
        case status
        when "D"
          # Have a dedicated report array for deleted casks.
          @report[:DC] << tap.formula_file_to_name(src)
        when "M"
          # Report updated casks
          @report[:MC] << tap.formula_file_to_name(src)
        end
      end

      next unless paths.any? { |p| tap.formula_file?(p) }

      case status
      when "A", "D"
        full_name = tap.formula_file_to_name(src)
        name = full_name.split("/").last
        new_tap = tap.tap_migrations[name]
        @report[status.to_sym] << full_name unless new_tap
      when "M"
        name = tap.formula_file_to_name(src)

        # Skip reporting updated formulae to speed up automatic updates.
        if preinstall
          @report[:M] << name
          next
        end

        begin
          formula = Formulary.factory(tap.path/src)
          new_version = formula.pkg_version
          old_version = FormulaVersions.new(formula).formula_at_revision(@initial_revision, &:pkg_version)
          next if new_version == old_version
        rescue FormulaUnavailableError
          # Don't care if the formula isn't available right now.
          nil
        rescue Exception => e # rubocop:disable Lint/RescueException
          onoe "#{e.message}\n#{e.backtrace.join "\n"}" if Homebrew::EnvConfig.developer?
        end

        @report[:M] << name
      when /^R\d{0,3}/
        src_full_name = tap.formula_file_to_name(src)
        dst_full_name = tap.formula_file_to_name(dst)
        # Don't report formulae that are moved within a tap but not renamed
        next if src_full_name == dst_full_name

        @report[:D] << src_full_name
        @report[:A] << dst_full_name
      end
    end

    renamed_formulae = Set.new
    @report[:D].each do |old_full_name|
      old_name = old_full_name.split("/").last
      new_name = tap.formula_renames[old_name]
      next unless new_name

      new_full_name = if tap.core_tap?
        new_name
      else
        "#{tap}/#{new_name}"
      end

      renamed_formulae << [old_full_name, new_full_name] if @report[:A].include? new_full_name
    end

    @report[:A].each do |new_full_name|
      new_name = new_full_name.split("/").last
      old_name = tap.formula_renames.key(new_name)
      next unless old_name

      old_full_name = if tap.core_tap?
        old_name
      else
        "#{tap}/#{old_name}"
      end

      renamed_formulae << [old_full_name, new_full_name]
    end

    if renamed_formulae.present?
      @report[:A] -= renamed_formulae.map(&:last)
      @report[:D] -= renamed_formulae.map(&:first)
    end

    # Only needed additions for calculating deletions correctly based on renames.
    @report.delete(:A)

    @report
  end

  def updated?
    initial_revision != current_revision
  end

  def migrate_tap_migration
    (report[:D] + report[:DC]).each do |full_name|
      name = full_name.split("/").last
      new_tap_name = tap.tap_migrations[name]
      next if new_tap_name.nil? # skip if not in tap_migrations list.

      new_tap_user, new_tap_repo, new_tap_new_name = new_tap_name.split("/")
      new_name = if new_tap_new_name
        new_full_name = new_tap_new_name
        new_tap_name = "#{new_tap_user}/#{new_tap_repo}"
        new_tap_new_name
      else
        new_full_name = "#{new_tap_name}/#{name}"
        name
      end

      # This means it is a cask
      if report[:DC].include? full_name
        next unless (HOMEBREW_PREFIX/"Caskroom"/new_name).exist?

        new_tap = Tap.fetch(new_tap_name)
        new_tap.install unless new_tap.installed?
        ohai "#{name} has been moved to Homebrew.", <<~EOS
          To uninstall the cask, run:
            brew uninstall --cask --force #{name}
        EOS
        next if (HOMEBREW_CELLAR/new_name.split("/").last).directory?

        ohai "Installing #{new_name}..."
        system HOMEBREW_BREW_FILE, "install", new_full_name
        begin
          unless Formulary.factory(new_full_name).keg_only?
            system HOMEBREW_BREW_FILE, "link", new_full_name, "--overwrite"
          end
        rescue Exception => e # rubocop:disable Lint/RescueException
          onoe "#{e.message}\n#{e.backtrace.join "\n"}" if Homebrew::EnvConfig.developer?
        end
        next
      end

      next unless (dir = HOMEBREW_CELLAR/name).exist? # skip if formula is not installed.

      tabs = dir.subdirs.map { |d| Tab.for_keg(Keg.new(d)) }
      next unless tabs.first.tap == tap # skip if installed formula is not from this tap.

      new_tap = Tap.fetch(new_tap_name)
      # For formulae migrated to cask: Auto-install cask or provide install instructions.
      if new_tap_name.start_with?("homebrew/cask")
        if new_tap.installed? && (HOMEBREW_PREFIX/"Caskroom").directory?
          ohai "#{name} has been moved to Homebrew Cask."
          ohai "brew unlink #{name}"
          system HOMEBREW_BREW_FILE, "unlink", name
          ohai "brew cleanup"
          system HOMEBREW_BREW_FILE, "cleanup"
          ohai "brew install --cask #{new_name}"
          system HOMEBREW_BREW_FILE, "install", "--cask", new_name
          ohai <<~EOS
            #{name} has been moved to Homebrew Cask.
            The existing keg has been unlinked.
            Please uninstall the formula when convenient by running:
              brew uninstall --force #{name}
          EOS
        else
          ohai "#{name} has been moved to Homebrew Cask.", <<~EOS
            To uninstall the formula and install the cask, run:
              brew uninstall --force #{name}
              brew tap #{new_tap_name}
              brew install --cask #{new_name}
          EOS
        end
      else
        new_tap.install unless new_tap.installed?
        # update tap for each Tab
        tabs.each { |tab| tab.tap = new_tap }
        tabs.each(&:write)
      end
    end
  end

  def migrate_formula_rename(force:, verbose:)
    Formula.installed.each do |formula|
      next unless Migrator.needs_migration?(formula)

      oldname = formula.oldname
      oldname_rack = HOMEBREW_CELLAR/oldname

      if oldname_rack.subdirs.empty?
        oldname_rack.rmdir_if_possible
        next
      end

      new_name = tap.formula_renames[oldname]
      next unless new_name

      new_full_name = "#{tap}/#{new_name}"

      begin
        f = Formulary.factory(new_full_name)
      rescue Exception => e # rubocop:disable Lint/RescueException
        onoe "#{e.message}\n#{e.backtrace.join "\n"}" if Homebrew::EnvConfig.developer?
        next
      end

      Migrator.migrate_if_needed(f, force: force)
    end
  end

  private

  def diff
    Utils.popen_read(
      "git", "-C", tap.path, "diff-tree", "-r", "--name-status", "--diff-filter=AMDR",
      "-M85%", initial_revision, current_revision
    )
  end
end

class ReporterHub
  extend T::Sig

  extend Forwardable

  attr_reader :reporters

  sig { void }
  def initialize
    @hash = {}
    @reporters = []
  end

  def select_formula(key)
    @hash.fetch(key, [])
  end

  def add(reporter, preinstall: false)
    @reporters << reporter
    report = reporter.report(preinstall: preinstall).delete_if { |_k, v| v.empty? }
    @hash.update(report) { |_key, oldval, newval| oldval.concat(newval) }
  end

  delegate empty?: :@hash

  def dump(updated_formula_report: true)
    if ENV["HOMEBREW_UPDATE_REPORT_ONLY_INSTALLED"]
      opoo "HOMEBREW_UPDATE_REPORT_ONLY_INSTALLED can be unset, it is now the default!"
    end

    # Key Legend: Added (A), Copied (C), Deleted (D), Modified (M), Renamed (R)
    if updated_formula_report
      dump_formula_report :M, "Updated Formulae"
    else
      updated = select_formula(:M).count
      ohai "Updated Formulae", "Updated #{updated} #{"formula".pluralize(updated)}." if updated.positive?
    end
    dump_formula_report :D, "Deleted Formulae"
    if updated_formula_report
      dump_formula_report :MC, "Updated Casks"
    else
      updated = select_formula(:MC).count
      ohai "Updated Casks", "Updated #{updated} #{"cask".pluralize(updated)}." if updated.positive?
    end
    dump_formula_report :DC, "Deleted Casks"
  end

  private

  def dump_formula_report(key, title)
    formulae = select_formula(key).sort.map do |name, _new_name|
      case key
      when :MC, :DC
        name = name.split("/").last
        pretty_installed(name) if cask_installed?(name)
      when :M, :D
        pretty_installed(name) if installed?(name)
      end
    end.compact

    return if formulae.empty?

    # Dump formula list.
    ohai title, Formatter.columns(formulae.sort)
  end

  def installed?(formula)
    (HOMEBREW_CELLAR/formula.split("/").last).directory?
  end

  def cask_installed?(cask)
    (Cask::Caskroom.path/cask).directory?
  end
end
