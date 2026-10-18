use clap::{Parser, Subcommand};
use std::path::PathBuf;
use thumble_receiver::{runtime, store::Store};

#[derive(Parser)]
#[command(
    version,
    about = "Thumble local Windows/Linux keyboard and mouse receiver"
)]
struct Cli {
    /// Private state directory; defaults to this user's platform data directory.
    #[arg(long, global = true)]
    state_dir: Option<PathBuf>,
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Run in the foreground. Stop with Ctrl+C or the stop command.
    Run {
        #[arg(long, default_value_t = 8765)]
        port: u16,
        #[arg(long)]
        no_bonjour: bool,
        /// Validate transport without creating an OS input device.
        #[arg(long)]
        no_input: bool,
    },
    Status,
    PairingCode,
    ReleaseAll,
    Stop,
    /// Import a portable ConfigurationDocument while the receiver is stopped.
    ImportConfiguration {
        path: PathBuf,
    },
}

#[tokio::main]
async fn main() {
    if let Err(error) = execute().await {
        eprintln!("thumble-receiver: {error}");
        std::process::exit(1);
    }
}

async fn execute() -> Result<(), String> {
    let cli = Cli::parse();
    let store = Store::open(cli.state_dir)?;
    match cli.command.unwrap_or(Command::Run {
        port: 8765,
        no_bonjour: false,
        no_input: false,
    }) {
        Command::Run {
            port,
            no_bonjour,
            no_input,
        } => runtime::run(store, port, !no_bonjour, !no_input).await,
        Command::ImportConfiguration { path } => store.import_configuration(&path),
        command => {
            let name = match command {
                Command::Status => "status",
                Command::PairingCode => "pairing-code",
                Command::ReleaseAll => "release-all",
                Command::Stop => "stop",
                _ => unreachable!(),
            };
            println!(
                "{}",
                serde_json::to_string_pretty(&runtime::control(&store, name).await?)
                    .map_err(|e| e.to_string())?
            );
            Ok(())
        }
    }
}
