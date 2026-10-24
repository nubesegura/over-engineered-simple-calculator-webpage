# Build target used by `sam build` for the AuthBffFunction of templates/auth-bff.yaml (Metadata BuildMethod
# makefile). It produces the same zip content as the Terraform archive_file of modules/auth-bff: handler.py
# and the .py files of the auth_bff package at the zip root, without tests, caches or tooling files. There is
# no runtime dependency to install (pyproject.toml declares none; the python3.14 runtime provides boto3).
# Run through `sam build --config-env <env>` (samconfig.toml sets build_in_source, so .venv is never copied).

.PHONY: build-AuthBffFunction

build-AuthBffFunction:
	cp handler.py "$(ARTIFACTS_DIR)/handler.py"
	cd src && find auth_bff -type f -name '*.py' -not -path '*/__pycache__/*' -exec cp --parents {} "$(ARTIFACTS_DIR)" \;
