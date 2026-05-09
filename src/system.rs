use crate::config::Config;
use crate::utils::run_command;
use crate::{die, vlog};
use colored::Colorize;
use std::collections::HashSet;


/// `use_refresh_command`: `true` only for **`-RU`** (`command_to_perform_system_update`). Otherwise
/// **`command_to_update_repositories`** (used for **`-R`** alone and **`-U`** without **`-R`**).
/// Always appends `ignore_flag` for each entry in `ignore_packages` and `manual_update_packages`
/// (deduped), so repo packages never replace packages you build with emerge.
pub fn run_system_update(config: &Config, use_refresh_command: bool) {
    let mut cmd_str = if use_refresh_command {
        config
            .system_update
            .command_to_perform_system_update
            .clone()
    } else {
        config.system_update.command_to_update_repositories.clone()
    };

    let mut seen = HashSet::new();
    for pkg in config
        .system_update
        .ignore_packages
        .iter()
        .chain(config.manual_update_packages.iter())
    {
        if seen.insert(pkg.clone()) {
            cmd_str.push_str(&format!(" {} {}", config.system_update.ignore_flag, pkg));
        }
    }

    vlog!("Executing system update: {}", cmd_str);

    // We run it via sh -c to allow complex yay commands from config
    if let Err(e) = run_command("sh", &["-c", &cmd_str], None::<&str>) {
        die!("System update failed: {}", e);
    }
}
