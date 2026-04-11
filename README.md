The Leaky Hybrid Bridge
Scenario
We have a legacy internal dashboard currently running on a developer's machine. Another team attempted to write Terraform to move this to the cloud, but the code is a mess. It is insecure, monolithic, and lacks automation. The target platform is AWS.

Your job is to prepare this for a production hybrid environment. Treat it the way you would treat any inherited codebase from a well-meaning but junior contributor who moved on: understand what they were trying to do, fix what is broken, and leave it in a state you would be comfortable handing off yourself.

There are no trick questions and no hidden requirements. The assets in this repo represent a real snapshot of where we were when the previous engineer left. Some issues are obvious and some are subtle — take the time to look carefully at each file before you start changing things.

Provided Assets
main.tf — A single Terraform file containing all infrastructure: VPC, subnet, security group, EC2 instance, and RDS database. State is stored locally.
Dockerfile — A Docker configuration for the application.
app.py — A Python Flask application that serves as the internal dashboard.
requirements.txt — Python dependencies.
Deliverables
1. Terraform Refactoring (IaC Best Practices)
Refactor the monolithic main.tf into logical, reusable modules
Secure the network configuration (subnets, security group rules)
Implement a remote state management strategy (e.g., S3 + DynamoDB locking)
Remove hardcoded secrets and implement secure secret injection
2. Containerization (Docker Best Practices)
Refactor the Dockerfile to be production-ready, minimal, and secure
Consider image size, the process that runs inside the container, and build reproducibility
3. Automation (CI/CD)
Write a CI/CD pipeline using GitHub Actions or GitLab CI
The pipeline must include linting and formatting steps (terraform fmt, tflint)
Run terraform plan on pull request and a simulated terraform apply on merge to main
4. Architecture Document
Explain the reasoning behind your Terraform module structure
Explain the secret management strategy you chose and why it fits this team's scale
Describe what observability tools you would add given more time and budget
Time
Plan for approximately 2-3 hours. If time runs short, prioritize depth over breadth: a well-reasoned partial submission with clear documentation of trade-offs is more useful than a rushed complete one. Wherever you stop, leave a brief note in your README explaining what you would have done next and why.

Submission
Push your work to a personal Git repository (GitHub, GitLab, or Bitbucket) and share the link. We will review the submission together in a follow-up conversation, so be prepared to walk through your decisions and answer questions about the choices you made.