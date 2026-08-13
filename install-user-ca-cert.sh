#!/bin/bash
set -e
if [[ -z "${1}" || -z "${2}" ]]; then
    echo "Usage: ${0} <Certificate Name> <Certificate File>" 2>&1
    exit 1
fi

if [[ ! -f "${2}" ]]; then
    echo "File ${2} not found." 2>&1
    exit 1
fi

CERT_FILE="${2}"
CERT_NAME="${1}"
FINGERPRINT=$(openssl x509 -noout -fingerprint -sha256 -in "${2}" | awk -F= '{ print $2 }' | tr -d '[:space:]')

echo "Certificate SHA256 fingerprint is ${FINGERPRINT}."

declare -a CHANGES

function setup_certificate() {
    CERT_DB="${1}"
    DB_TYPE="${2}"

    CERT_DIR=${DB_TYPE}$(dirname "${CERT_DB}")
    INSTALL="no"
    TRUST_FLAGS=$(certutil -L -d "${CERT_DIR}" | grep -E "${CERT_NAME}\s" | awk '{ print $2 }')

    if [[ ! -z "${TRUST_FLAGS}" ]]; then
        EXISTING_FINGERPRINT=$(certutil -L -n "${CERT_NAME}" -d "${CERT_DIR}" | grep -A1 'Fingerprint (SHA-256)' | grep -v Fingerprint | tr -d '[:space:]')

        if [[ ! "${FINGERPRINT}" = "${EXISTING_FINGERPRINT}" ]]; then
            echo "Existing certificate out of date, deleting..."
            certutil -D -n "${CERT_NAME}" -d "${CERT_DIR}"

            INSTALL="yes"
        elif [[ "${TRUST_FLAGS}" != "Cu,Cu,Cu" ]]; then
            echo "Trusting existing certificate..."
            certutil -M -n "${CERT_NAME}" -t Cu,Cu,Cu -d "${CERT_DIR}"
        fi
    else
        INSTALL="yes"
    fi

    if [[ "${INSTALL}" = "yes" ]]; then
        echo "Importing ${CERT_NAME} from ${CERT_FILE} into ${CERT_DB}..."
        certutil -A -n "${CERT_NAME}" -t "Cu,Cu,Cu" -i "${CERT_FILE}" -d "${CERT_DIR}"

        CHANGES+=("${CERT_DIR}")
    fi
}

while IFS= read -r -d '' CERT_DB; do
    setup_certificate "${CERT_DB}"
done < <(find ~/ -name "cert8.db" -print0)

# Eh, screw the Flash Player.
while IFS= read -r -d '' CERT_DB; do
    setup_certificate "${CERT_DB}" "sql:"
done < <(find ~/ -name "cert9.db" ! -path "*Flash_Player*" -print0)

echo "Updated certificate databases' databases='${CHANGES[*]}'"
