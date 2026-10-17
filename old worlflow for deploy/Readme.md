# Manual Deployment (Without Ansible)

Use this option if you want to configure and deploy the application manually without using Ansible.

Copy the deployment workflow file into `.github/workflows/deploy.yml` in your repository. GitHub Actions will then use this workflow to execute the deployment process according to its configuration.

**Note:** Ensure that the workflow file is correctly configured with the required deployment steps, secrets, environment variables, and server access credentials before triggering the deployment.
