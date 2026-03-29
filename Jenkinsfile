pipeline {
  // Download releases from GitHub and deploy them
  agent { label 'built-in' }

  options {
    timeout(time: 30, unit: 'MINUTES')
    timestamps()
  }

  triggers {
    // Poll GitHub every 5 minutes for new commits
    pollSCM('H/5 * * * *')
  }

  environment {
    BOT_NAME = 'job_applications'
    RELEASE_NAME = 'bot_army_job_applications'
    STATE_NAME = 'bot_army_job_applications'
    RELEASE_DIR = "/opt/ergon/releases/${BOT_NAME}"
    GITHUB_REPO = "ergon-automation-labs/ergon-job_applications"
    SALT_TARGET = '-G bot_army_node_type:air'
  }

  stages {

    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Download Build Artifact') {
      steps {
        sh '''
          echo "==============================================="
          echo "Downloading pre-built release from GitHub"
          echo "==============================================="

          # Get the latest published release (not a draft)
          LATEST_RELEASE=$(gh api repos/${GITHUB_REPO}/releases \
            -q '.[] | select(.draft==false) | .tag_name' | head -1)

          if [ -z "$LATEST_RELEASE" ]; then
            echo "ERROR: No published release found on GitHub"
            exit 1
          fi

          echo "Latest release: $LATEST_RELEASE"

          # Download the tarball asset
          echo "Downloading: ${RELEASE_NAME}-*.tar.gz"
          mkdir -p ./release-artifact

          gh release download $LATEST_RELEASE \
            --repo ${GITHUB_REPO} \
            --pattern "*.tar.gz" \
            -D ./release-artifact

          echo "✓ Release downloaded successfully"

          # Extract tarball
          cd ./release-artifact
          TARBALL=$(ls -1 *.tar.gz | head -1)
          echo "Extracting: $TARBALL"
          tar -xzf "$TARBALL"
          rm "$TARBALL"
          ls -la
          cd ..
        '''
      }
    }

    stage('Sync Job Boards to Salt') {
      steps {
        sh '''
          echo "==============================================="
          echo "Syncing job boards to Salt pillar"
          echo "==============================================="

          TMP_ROOT="${WORKSPACE_TMP_ROOT:-/tmp/bot_army}"
          ERGON_TOP_DIR="${TMP_ROOT}/ergon_top"
          ERGON_TOP_URL="${ERGON_TOP_URL:-https://github.com/ergon-automation-labs/ergon_top_directory.git}"
          ERGON_TOP_BRANCH="${ERGON_TOP_BRANCH:-main}"

          mkdir -p "${TMP_ROOT}" 2>/dev/null || true

          # Clone or update fresh ergon_top_directory workspace
          if git -C "${ERGON_TOP_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            echo "Updating existing workspace..."
            if ! git -C "${ERGON_TOP_DIR}" fetch origin "${ERGON_TOP_BRANCH}" >/dev/null 2>&1; then
              echo "⚠️  Failed to fetch workspace, using existing state"
            else
              git -C "${ERGON_TOP_DIR}" checkout "${ERGON_TOP_BRANCH}" >/dev/null 2>&1 || true
              git -C "${ERGON_TOP_DIR}" reset --hard "origin/${ERGON_TOP_BRANCH}" >/dev/null 2>&1 || true
            fi
          else
            echo "Cloning fresh ergon_top_directory workspace..."
            rm -rf "${ERGON_TOP_DIR}" >/dev/null 2>&1 || true
            if ! git clone --depth 1 --branch "${ERGON_TOP_BRANCH}" "${ERGON_TOP_URL}" "${ERGON_TOP_DIR}" >/dev/null 2>&1; then
              echo "⚠️  Failed to clone workspace, skipping board sync"
              exit 0
            fi
          fi

          # Discover boards and update pillar using workspace scripts
          echo "Discovering active job boards..."
          cd "${ERGON_TOP_DIR}/bot_army_job_applications"
          bash "${ERGON_TOP_DIR}/scripts/mise-exec.sh" mix job_applications.sync_boards_to_salt || {
            echo "⚠️  Board sync failed, but continuing"
            exit 0
          }

          # Commit and push updated pillar
          cd "${ERGON_TOP_DIR}/bot_army_infra"
          if git diff --quiet salt/pillar/job_applications.sls 2>/dev/null; then
            echo "✓ No board changes detected"
          else
            echo "Board configuration changed, committing and pushing..."
            git add salt/pillar/job_applications.sls
            git commit -m "Auto-sync: update job board configuration from job_applications discovery" >/dev/null 2>&1 || true
            if git push origin "${ERGON_TOP_BRANCH}" >/dev/null 2>&1; then
              echo "✓ Pushed board changes to bot_army_infra"
            else
              echo "⚠️  Push to bot_army_infra failed (non-blocking)"
            fi
          fi

          cd "${WORKSPACE}"
          echo "✓ Board sync complete"
        '''
      }
    }

    stage('Deploy') {
      steps {
        sh '''
          echo "==============================================="
          echo "Deploying release"
          echo "==============================================="
          echo "Start time: $(date)"

          TIMESTAMP=$(date +%Y%m%d%H%M%S)
          DEST="${RELEASE_DIR}/releases/${TIMESTAMP}"

          echo "Creating release directory..."
          mkdir -p "${DEST}"

          echo "Copying release artifacts..."
          cp -r ./release-artifact/* "${DEST}/"

          echo "Updating current symlink..."
          ln -sfn "${DEST}" "${RELEASE_DIR}/current"

          # Deploy via Salt using fresh bot_army_infra checkout + ergon_top scripts
          TMP_ROOT="${WORKSPACE_TMP_ROOT:-/tmp/bot_army}"
          ERGON_TOP_DIR="${TMP_ROOT}/ergon_top"
          ERGON_TOP_URL="${ERGON_TOP_URL:-https://github.com/ergon-automation-labs/ergon_top_directory.git}"
          ERGON_TOP_BRANCH="${ERGON_TOP_BRANCH:-main}"
          INFRA_REPO_DIR="${TMP_ROOT}/bot_army_infra"
          INFRA_REPO_URL="${INFRA_REPO_URL:-https://github.com/ergon-automation-labs/ergon-infra.git}"
          INFRA_REPO_BRANCH="${INFRA_REPO_BRANCH:-main}"

          # Ensure fresh ergon_top_directory checkout
          if git -C "${ERGON_TOP_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            echo "Updating existing ergon_top_directory checkout..."
            git -C "${ERGON_TOP_DIR}" fetch origin "${ERGON_TOP_BRANCH}" >/dev/null 2>&1 || true
            git -C "${ERGON_TOP_DIR}" checkout "${ERGON_TOP_BRANCH}" >/dev/null 2>&1 || true
            git -C "${ERGON_TOP_DIR}" reset --hard "origin/${ERGON_TOP_BRANCH}" >/dev/null 2>&1 || true
          else
            echo "Cloning fresh ergon_top_directory checkout..."
            rm -rf "${ERGON_TOP_DIR}" >/dev/null 2>&1 || true
            git clone --depth 1 --branch "${ERGON_TOP_BRANCH}" "${ERGON_TOP_URL}" "${ERGON_TOP_DIR}" >/dev/null 2>&1 || true
          fi

          # Ensure fresh bot_army_infra checkout
          if git -C "${INFRA_REPO_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            echo "Updating existing bot_army_infra checkout..."
            git -C "${INFRA_REPO_DIR}" fetch origin "${INFRA_REPO_BRANCH}" >/dev/null 2>&1 || true
            git -C "${INFRA_REPO_DIR}" checkout "${INFRA_REPO_BRANCH}" >/dev/null 2>&1 || true
            git -C "${INFRA_REPO_DIR}" reset --hard "origin/${INFRA_REPO_BRANCH}" >/dev/null 2>&1 || true
          else
            echo "Cloning fresh bot_army_infra checkout..."
            rm -rf "${INFRA_REPO_DIR}" >/dev/null 2>&1 || true
            git clone --depth 1 --branch "${INFRA_REPO_BRANCH}" "${INFRA_REPO_URL}" "${INFRA_REPO_DIR}" >/dev/null 2>&1 || true
          fi

          if [ -d "${INFRA_REPO_DIR}" ] && [ -f "${INFRA_REPO_DIR}/Makefile" ]; then
            echo "Deploying service via Salt..."
            cd "${INFRA_REPO_DIR}"
            make deploy-bot BOT=${BOT_NAME} || {
              echo "⚠️  make deploy-bot failed, attempting manual Salt apply"
              cd "${WORKSPACE}/bot_army_job_applications"
            }
          else
            echo "Fresh bot_army_infra checkout not available, using manual Salt apply..."
            cd "${WORKSPACE}/bot_army_job_applications"
          fi

          # Fallback manual Salt apply if make deploy-bot not available
          if [ ! -f "${RELEASE_DIR}/current/${RELEASE_NAME}/bin/${RELEASE_NAME}" ] || ! command -v make >/dev/null; then
            echo "Applying Salt configuration manually..."
            salt_apply() {
              local state=$1 attempt=0
              until sudo /opt/salt/salt ${SALT_TARGET} state.apply $state; do
                attempt=$((attempt + 1))
                if [ $attempt -ge 3 ]; then echo "salt state.apply $state failed after 3 attempts"; return 1; fi
                echo "Salt busy, retrying in 30s... (attempt $attempt/3)"
                sleep 30
              done
            }
            salt_apply common.core
            salt_apply common.schemas
            salt_apply bots.${STATE_NAME}

            echo "Restarting service..."
            sudo launchctl unload /Library/LaunchDaemons/com.botarmy.${BOT_NAME}.plist 2>/dev/null || true
            sleep 2
            sudo launchctl load -w /Library/LaunchDaemons/com.botarmy.${BOT_NAME}.plist
          fi

          echo "Checking service health..."
          /opt/bot_army/scripts/health_check.sh ${BOT_NAME}

          echo "Deploy complete!"
          echo "Completion time: $(date)"
        '''
      }
    }

    stage('Run Migrations') {
      steps {
        sh '''
          echo "==============================================="
          echo "Running database migrations"
          echo "==============================================="

          # Get the release binary path
          RELEASE_BIN="${RELEASE_DIR}/current/${RELEASE_NAME}/bin/${RELEASE_NAME}"

          if [ ! -f "$RELEASE_BIN" ]; then
            echo "⚠️  Release binary not found at $RELEASE_BIN"
            echo "Skipping migrations (may already be at correct schema)"
            exit 0
          fi

          # Run migrations using the release
          echo "Running: $RELEASE_BIN eval 'BotArmyJobApplications.Release.migrate()'"

          $RELEASE_BIN eval 'BotArmyJobApplications.Release.migrate()' || {
            echo "⚠️  Migration failed or Release module not found"
            echo "Continuing with deployment (manual migration may be needed)"
          }

          echo "✓ Migrations complete"
        '''
      }
    }

  }

  post {
    success {
      sh '''
        # Extract version from the deployed release
        START_ERL="${RELEASE_DIR}/current/${RELEASE_NAME}/releases/start_erl.data"
        if [ -f "$START_ERL" ]; then
          VERSION=$(awk '{print $2}' "$START_ERL")
        else
          VERSION="unknown"
        fi

        # Extract release timestamp and git SHA
        TIMESTAMP=$(basename $(readlink "${RELEASE_DIR}/current"))
        GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

        # Build JSON payload
        PAYLOAD=$(cat <<EOF
{"bot":"${BOT_NAME}","node":"air","triggered_by":"jenkins","status":"success","version":"${VERSION}","release":"${TIMESTAMP}","sha":"${GIT_SHA}"}
EOF
)
        echo "📢 Notifying NATS of successful deployment..."
        /opt/bot_army/scripts/nats_publish.sh ops.builds.${BOT_NAME} "$PAYLOAD" || echo "⚠️  NATS notification failed (non-blocking)"
      '''
    }
    failure {
      sh '''
        # Build JSON payload for failure
        PAYLOAD=$(cat <<EOF
{"bot":"${BOT_NAME}","node":"air","triggered_by":"jenkins","status":"failed"}
EOF
)
        echo "📢 Notifying NATS of failed deployment..."
        /opt/bot_army/scripts/nats_publish.sh ops.builds.${BOT_NAME} "$PAYLOAD" || echo "⚠️  NATS notification failed (non-blocking)"
      '''
    }
    always {
      cleanWs()
    }
  }
}
