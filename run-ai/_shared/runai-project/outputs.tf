output "project_id" {
  description = "ID of the created NVIDIA Run:ai project"
  value       = restful_operation.project.output.id
}

output "department_id" {
  description = "ID of the department the project belongs to"
  value       = restful_operation.departments.output[0].id
}
