#!/bin/sh

FEATURES="zsh tmux claude-code"
USERS="root nobody test_user"
IMAGES="debian:13-slim ubuntu alpine"

cleanup() {
    echo "Cleaning up test images..."
    docker rmi feature-test-debian feature-test-alpine 2>/dev/null || true
}

for image in $IMAGES; do
    docker build -t "feature-test-$(echo $image | tr ':' '-')" -<<EOF
FROM ${image}
RUN useradd -m -s /bin/bash test_user || adduser -D -s /bin/sh test_user
EOF

    if [ ${?} -ne 0 ]; then
        echo "Failed to create feature-test-$(echo $image | tr ':' '-') image"
        cleanup
        exit 1
    fi
done

# Test with specific users (including testuser)
for feature in $FEATURES; do
    for image in $IMAGES; do
        # Test with automatic user detection (no -u flag)
        # This tests the "automatic" username logic in install.sh
        echo "Testing with ${feature}, ${image}, automatic (default)"
        devcontainer features test --skip-scenarios --skip-duplicated -f "${feature}" -i "${image}" .

        if [ ${?} -ne 0 ]; then
            echo "Test failed for ${feature}, ${image}, automatic (default)"
            cleanup
            exit 1
        fi

        for user in $USERS; do
            # Skip testing claude-code with nobody user due to HOME directory issues
            if [ "${user}" = "nobody" ] &&  [ "${feature}" = "claude-code" ]; then
                echo "Skipping claude-code test with nobody user due to HOME directory issues"
                continue
            fi

            if [ "${user}" = "test_user" ]; then
                image="feature-test-$(echo $image | tr ':' '-')"
            fi

            echo "Testing with ${feature}, ${image}, ${user}"
            devcontainer features test --skip-scenarios --skip-duplicated -f "${feature}" -i "${image}" -u "${user}" .

            if [ ${?} -ne 0 ]; then
                echo "Test failed for ${feature}, ${image}, ${user}"
                cleanup
                exit 1
            fi
        done
    done
done

cleanup
echo "All tests passed."
