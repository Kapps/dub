/**
	A package manager.

	Copyright: © 2012-2013 Matthias Dondorff
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Matthias Dondorff, Sönke Ludwig
*/
module dub.dub;

import dub.compilers.compiler;
import dub.dependency;
import dub.internal.utils;
import dub.internal.vibecompat.core.file;
import dub.internal.vibecompat.core.log;
import dub.internal.vibecompat.data.json;
import dub.internal.vibecompat.inet.url;
import dub.package_;
import dub.packagemanager;
import dub.packagesupplier;
import dub.project;
import dub.generators.generator;
import dub.init;


// todo: cleanup imports.
import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.process;
import std.string;
import std.typecons;
import std.zip;



/// The default supplier for packages, which is the registry
/// hosted by code.dlang.org.
PackageSupplier[] defaultPackageSuppliers()
{
	Url url = Url.parse("http://code.dlang.org/");
	logDiagnostic("Using dub registry url '%s'", url);
	return [new RegistryPackageSupplier(url)];
}

/// The Dub class helps in getting the applications
/// dependencies up and running. An instance manages one application.
class Dub {
	private {
		PackageManager m_packageManager;
		PackageSupplier[] m_packageSuppliers;
		Path m_rootPath, m_tempPath;
		Path m_userDubPath, m_systemDubPath;
		Json m_systemConfig, m_userConfig;
		Path m_projectPath;
		Project m_project;
	}

	/// Initiales the package manager for the vibe application
	/// under root.
	this(PackageSupplier[] additional_package_suppliers = null, string root_path = ".")
	{
		m_rootPath = Path(root_path);
		if (!m_rootPath.absolute) m_rootPath = Path(getcwd()) ~ m_rootPath;

		version(Windows){
			m_systemDubPath = Path(environment.get("ProgramData")) ~ "dub/";
			m_userDubPath = Path(environment.get("APPDATA")) ~ "dub/";
			m_tempPath = Path(environment.get("TEMP"));
		} else version(Posix){
			m_systemDubPath = Path("/var/lib/dub/");
			m_userDubPath = Path(environment.get("HOME")) ~ ".dub/";
			m_tempPath = Path("/tmp");
		}
		
		m_userConfig = jsonFromFile(m_userDubPath ~ "settings.json", true);
		m_systemConfig = jsonFromFile(m_systemDubPath ~ "settings.json", true);

		PackageSupplier[] ps = additional_package_suppliers;
		if (auto pp = "registryUrls" in m_userConfig) ps ~= deserializeJson!(string[])(*pp).map!(url => new RegistryPackageSupplier(Url(url))).array;
		if (auto pp = "registryUrls" in m_systemConfig) ps ~= deserializeJson!(string[])(*pp).map!(url => new RegistryPackageSupplier(Url(url))).array;
		ps ~= defaultPackageSuppliers();

		m_packageSuppliers = ps;
		m_packageManager = new PackageManager(m_userDubPath, m_systemDubPath);
		updatePackageSearchPath();
	}

	/** Returns the root path (usually the current working directory).
	*/
	@property Path rootPath() const { return m_rootPath; }
	/// ditto
	@property void rootPath(Path root_path)
	{
		m_rootPath = root_path;
		if (!m_rootPath.absolute) m_rootPath = Path(getcwd()) ~ m_rootPath;
	}

	/// Returns the name listed in the package.json of the current
	/// application.
	@property string projectName() const { return m_project.name; }

	@property Path projectPath() const { return m_projectPath; }

	@property string[] configurations() const { return m_project.configurations; }

	@property inout(PackageManager) packageManager() inout { return m_packageManager; }

	/// Loads the package from the current working directory as the main
	/// project package.
	void loadPackageFromCwd()
	{
		loadPackage(m_rootPath);
	}

	/// Loads the package from the specified path as the main project package.
	void loadPackage(Path path)
	{
		m_projectPath = path;
		updatePackageSearchPath();
		m_project = new Project(m_packageManager, m_projectPath);
	}

	/// Loads a specific package as the main project package (can be a sub package)
	void loadPackage(Package pack)
	{
		m_projectPath = pack.path;
		updatePackageSearchPath();
		m_project = new Project(m_packageManager, pack);
	}

	string getDefaultConfiguration(BuildPlatform platform) const { return m_project.getDefaultConfiguration(platform); }

	/// Performs retrieval and removal as necessary for
	/// the application.
	/// @param options bit combination of UpdateOptions
	void update(UpdateOptions options)
	{
		bool[string] masterVersionUpgrades;
		while (true) {
			Action[] allActions = m_project.determineActions(m_packageSuppliers, options);
			Action[] actions;
			foreach(a; allActions)
				if(a.packageId !in masterVersionUpgrades)
					actions ~= a;

			if (actions.length == 0) break;

			logInfo("The following changes will be performed:");
			bool conflictedOrFailed = false;
			foreach(Action a; actions) {
				logInfo("%s %s %s, %s", capitalize(to!string(a.type)), a.packageId, a.vers, a.location);
				if( a.type == Action.Type.conflict || a.type == Action.Type.failure ) {
					logInfo("Issued by: ");
					conflictedOrFailed = true;
					foreach(string pkg, d; a.issuer)
						logInfo(" "~pkg~": %s", d);
				}
			}

			if (conflictedOrFailed || options & UpdateOptions.JustAnnotate) return;

			// Remove first
			foreach(Action a; filter!((Action a) => a.type == Action.Type.remove)(actions)) {
				assert(a.pack !is null, "No package specified for removal.");
				remove(a.pack);
			}
			foreach(Action a; filter!((Action a) => a.type == Action.Type.fetch)(actions)) {
				fetch(a.packageId, a.vers, a.location, (options & UpdateOptions.Upgrade) != 0);
				// never update the same package more than once
				masterVersionUpgrades[a.packageId] = true;
			}

			m_project.reinit();
		}
	}

	/// Generate project files for a specified IDE.
	/// Any existing project files will be overridden.
	void generateProject(string ide, GeneratorSettings settings) {
		auto generator = createProjectGenerator(ide, m_project, m_packageManager);
		generator.generateProject(settings);
	}

	/// Outputs a JSON description of the project, including its dependencies.
	void describeProject(BuildPlatform platform, string config)
	{
		auto dst = Json.emptyObject;
		dst.configuration = config;
		dst.compiler = platform.compiler;
		dst.architecture = platform.architecture.serializeToJson();
		dst.platform = platform.platform.serializeToJson();

		m_project.describe(dst, platform, config);
		logInfo("%s", dst.toPrettyString());
	}


	/// Returns all cached  packages as a "packageId" = "version" associative array
	string[string] cachedPackages() const { return m_project.cachedPackagesIDs(); }

	/// Fetches the package matching the dependency and places it in the specified location.
	Package fetch(string packageId, const Dependency dep, PlacementLocation location, bool force_branch_upgrade)
	{
		Json pinfo;
		PackageSupplier supplier;
		foreach(ps; m_packageSuppliers){
			try {
				pinfo = ps.getPackageDescription(packageId, dep);
				supplier = ps;
				break;
			} catch(Exception) {}
		}
		enforce(pinfo.type != Json.Type.undefined, "No package "~packageId~" was found matching the dependency "~dep.toString());
		string ver = pinfo["version"].get!string;

		Path placement;
		final switch (location) {
			case PlacementLocation.local: placement = m_rootPath; break;
			case PlacementLocation.userWide: placement = m_userDubPath ~ "packages/"; break;
			case PlacementLocation.systemWide: placement = m_systemDubPath ~ "packages/"; break;
		}

		// always upgrade branch based versions - TODO: actually check if there is a new commit available
		if (auto pack = m_packageManager.getPackage(packageId, ver, placement)) {
			if (!ver.startsWith("~") || !force_branch_upgrade || location == PlacementLocation.local) {
				// TODO: support git working trees by performing a "git pull" instead of this
				logInfo("Package %s %s (%s) is already present with the latest version, skipping upgrade.",
					packageId, ver, placement);
				return pack;
			} else {
				logInfo("Removing present package of %s %s", packageId, ver);
				m_packageManager.remove(pack);
			}
		}

		logInfo("Fetching %s %s...", packageId, ver);

		logDiagnostic("Acquiring package zip file");
		auto dload = m_projectPath ~ ".dub/temp/downloads";
		auto tempfname = packageId ~ "-" ~ (ver.startsWith('~') ? ver[1 .. $] : ver) ~ ".zip";
		auto tempFile = m_tempPath ~ tempfname;
		string sTempFile = tempFile.toNativeString();
		if (exists(sTempFile)) std.file.remove(sTempFile);
		supplier.retrievePackage(tempFile, packageId, dep); // Q: continue on fail?
		scope(exit) std.file.remove(sTempFile);

		logInfo("Placing %s %s to %s...", packageId, ver, placement.toNativeString());
		auto clean_package_version = ver[ver.startsWith("~") ? 1 : 0 .. $];
		Path dstpath = placement ~ (packageId ~ "-" ~ clean_package_version);

		return m_packageManager.get(tempFile, pinfo, dstpath);
	}

	/// Removes a given package from the list of present/cached modules.
	/// @removeFromApplication: if true, this will also remove an entry in the
	/// list of dependencies in the application's package.json
	void remove(in Package pack)
	{
		logInfo("Removing %s in %s", pack.name, pack.path.toNativeString());
		m_packageManager.remove(pack);
	}

	/// @see remove(string, string, RemoveLocation)
	enum RemoveVersionWildcard = "*";

	/// This will remove a given package with a specified version from the 
	/// location.
	/// It will remove at most one package, unless @param version_ is 
	/// specified as wildcard "*". 
	/// @param package_id Package to be removed
	/// @param version_ Identifying a version or a wild card. An empty string
	/// may be passed into. In this case the package will be removed from the
	/// location, if there is only one version retrieved. This will throw an
	/// exception, if there are multiple versions retrieved.
	/// Note: as wildcard string only "*" is supported.
	/// @param location_
	void remove(string package_id, string version_, PlacementLocation location_) {
		enforce(!package_id.empty);
		if (location_ == PlacementLocation.local) {
			logInfo("To remove a locally placed package, make sure you don't have any data"
					~ "\nleft in it's directory and then simply remove the whole directory.");
			return;
		}

		Package[] packages;
		const bool wildcardOrEmpty = version_ == RemoveVersionWildcard || version_.empty;

		// Use package manager
		foreach(pack; m_packageManager.getPackageIterator(package_id)) {
			if( wildcardOrEmpty || pack.vers == version_ ) {
				packages ~= pack;
			}
		}

		if(packages.empty) {
			logError("Cannot find package to remove. (id:%s, version:%s, location:%s)", package_id, version_, location_);
			return;
		}

		if(version_.empty && packages.length > 1) {
			logError("Cannot remove package '%s', there multiple possibilities at location '%s'.", package_id, location_);
			logError("Retrieved versions:");
			foreach(pack; packages) 
				logError(to!string(pack.vers()));
			throw new Exception("Failed to remove package.");
		}

		logDebug("Removing %s packages.", packages.length);
		foreach(pack; packages) {
			try {
				remove(pack);
				logInfo("Removing %s, version %s.", package_id, pack.vers);
			}
			catch logError("Failed to remove %s, version %s. Continuing with other packages (if any).", package_id, pack.vers);
		}
	}

	void addLocalPackage(string path, string ver, bool system)
	{
		m_packageManager.addLocalPackage(makeAbsolute(path), Version(ver), system ? LocalPackageType.system : LocalPackageType.user);
	}

	void removeLocalPackage(string path, bool system)
	{
		m_packageManager.removeLocalPackage(makeAbsolute(path), system ? LocalPackageType.system : LocalPackageType.user);
	}

	void addSearchPath(string path, bool system)
	{
		m_packageManager.addSearchPath(makeAbsolute(path), system ? LocalPackageType.system : LocalPackageType.user);
	}

	void removeSearchPath(string path, bool system)
	{
		m_packageManager.removeSearchPath(makeAbsolute(path), system ? LocalPackageType.system : LocalPackageType.user);
	}

	void createEmptyPackage(Path path, string type)
	{
		if( !path.absolute() ) path = m_rootPath ~ path;
		path.normalize();

		initPackage(path, type);

		//Act smug to the user. 
		logInfo("Successfully created an empty project in '%s'.", path.toNativeString());
	}

	void runDdox(bool run)
	{
		auto ddox_pack = m_packageManager.getBestPackage("ddox", ">=0.0.0");
		if (!ddox_pack) ddox_pack = m_packageManager.getBestPackage("ddox", "~master");
		if (!ddox_pack) {
			logInfo("DDOX is not present, getting it and storing user wide");
			ddox_pack = fetch("ddox", Dependency(">=0.0.0"), PlacementLocation.userWide, false);
		}

		version(Windows) auto ddox_exe = "ddox.exe";
		else auto ddox_exe = "ddox";

		if( !existsFile(ddox_pack.path~ddox_exe) ){
			logInfo("DDOX in %s is not built, performing build now.", ddox_pack.path.toNativeString());

			auto ddox_dub = new Dub(m_packageSuppliers);
			ddox_dub.loadPackage(ddox_pack.path);

			auto compiler_binary = "dmd";

			GeneratorSettings settings;
			settings.config = "application";
			settings.compiler = getCompiler(compiler_binary);
			settings.platform = settings.compiler.determinePlatform(settings.buildSettings, compiler_binary);
			settings.buildType = "debug";
			ddox_dub.generateProject("build", settings);

			//runCommands(["cd "~ddox_pack.path.toNativeString()~" && dub build -v"]);
		}

		auto p = ddox_pack.path;
		p.endsWithSlash = true;
		auto dub_path = p.toNativeString();

		string[] commands;
		string[] filterargs = m_project.mainPackage.info.ddoxFilterArgs.dup;
		if (filterargs.empty) filterargs = ["--min-protection=Protected", "--only-documented"];
		commands ~= dub_path~"ddox filter "~filterargs.join(" ")~" docs.json";
		if (!run) {
			commands ~= dub_path~"ddox generate-html --navigation-type=ModuleTree docs.json docs";
			version(Windows) commands ~= "xcopy /S /D "~dub_path~"public\\* docs\\";
			else commands ~= "cp -r \""~dub_path~"public\"/* docs/";
		}
		runCommands(commands);

		if (run) {
			spawnProcess([dub_path~"ddox", "serve-html", "--navigation-type=ModuleTree", "docs.json", "--web-file-dir="~dub_path~"public"]);
			browse("http://127.0.0.1:8080/");
		}
	}

	private void updatePackageSearchPath()
	{
		auto p = environment.get("DUBPATH");
		Path[] paths;

		version(Windows) enum pathsep = ":";
		else enum pathsep = ";";
		if (p.length) paths ~= p.split(pathsep).map!(p => Path(p))().array();
		m_packageManager.searchPath = paths;
	}

	private Path makeAbsolute(Path p) const { return p.absolute ? p : m_rootPath ~ p; }
	private Path makeAbsolute(string p) const { return makeAbsolute(Path(p)); }
}
