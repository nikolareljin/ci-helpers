# ollama

Helpers to install the Ollama CLI, prepare a models index, select a model/size via dialog, and pull/run models.

Expected imports
----------------

- logging, os, dialog, file, json, env

Functions
---------

- ollama_install_cli
  - Purpose: Install the Ollama CLI (Linux/macOS). Prints an error on unsupported platforms.
  - Linux: `curl -fsSL https://ollama.com/install.sh | sh`
  - macOS: `brew install ollama/tap/ollama`

- ollama_prepare_models_index [repo_dir=ollama-get-models] [repo_url=https://github.com/webfarmer/ollama-get-models.git]
  - Purpose: Ensure a repo containing the models index exists; update/clone; generate `code/ollama_models.json`.
  - Behavior: Runs `python3 get_ollama_models.py` if present; sorts JSON by name; prints path to the JSON.
  - Returns: non-zero on failure.

- ollama_models_json_path [repo_dir=ollama-get-models]
  - Purpose: Convenience function to print the expected JSON path within the repo.

- ollama_list_models json_file
  - Purpose: Print model names from the JSON index.

- ollama_dialog_select_model json_file [current_model]
  - Purpose: Use a dialog radiolist to select a model; returns selected name on stdout.

- ollama_dialog_select_size json_file model [current_size]
  - Purpose: Use a dialog menu to select a size for the model; returns `latest` if none are listed.

- ollama_pull_model model [size=latest]
  - Purpose: `ollama pull name:size`.

- ollama_run_model model [size=latest]
  - Purpose: `nohup ollama run name:size &`.

- ollama_update_env [env_file=.env] key value
  - Purpose: Create/update a `key=value` line in a dotenv file.

- ollama_install_model_flow [repo_dir=ollama-get-models] [env_file]
  - Purpose: Full flow: ensure index, select model and size, optionally persist to env, then `ollama pull` the selection.

Dependencies
------------

- `curl`, `git`, `python3`, `jq`, `dialog`, `ollama`.

