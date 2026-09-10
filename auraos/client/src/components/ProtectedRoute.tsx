import { Navigate, useLocation } from 'react-router-dom'
import { useAuth } from '../contexts/AuthContext'

interface ProtectedRouteProps {
  children: React.ReactNode
  roles?: string[]  // if provided, only these roles can access
  superAdminOnly?: boolean  // if true, only super admins can access
}

const ProtectedRoute: React.FC<ProtectedRouteProps> = ({ children, roles, superAdminOnly }) => {
  const { isAuthenticated, isLoading, user } = useAuth()
  const location = useLocation()

  if (isLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="h-10 w-10 rounded-full border-2 border-gray-200 border-t-indigo-600 animate-spin" />
      </div>
    )
  }

  if (!isAuthenticated) {
    return <Navigate to="/login" replace />
  }

  // Super-admin guard — redirect to dashboard if user is not a super admin
  if (superAdminOnly && user && !user.isSuperAdmin) {
    return <Navigate to="/" replace />
  }

  // Role guard — redirect to dashboard if user doesn't have required role
  if (roles && roles.length > 0 && user && !roles.includes(user.role)) {
    return <Navigate to="/" replace />
  }

  // The AI analytics service is a separate deployable. In preview, never let a
  // missing AI deployment crash React or send requests to GitHub Pages itself.
  // Once a real service exists, VITE_AI_API_BASE_URL enables all AI routes again.
  const aiBaseUrl = (import.meta.env.VITE_AI_API_BASE_URL as string | undefined)?.trim()
  if (location.pathname.startsWith('/ai') && !aiBaseUrl) {
    return (
      <div className="min-h-screen bg-gray-50 flex items-center justify-center p-6">
        <div className="w-full max-w-xl rounded-2xl border border-amber-200 bg-white p-8 shadow-sm">
          <div className="mb-4 inline-flex h-12 w-12 items-center justify-center rounded-full bg-amber-100 text-amber-700 text-xl font-bold">AI</div>
          <h1 className="text-2xl font-bold text-gray-900">AI service is not available yet</h1>
          <p className="mt-3 text-sm leading-6 text-gray-600">
            AuraOS core is running normally, but the separate AI Analytics service has not been deployed for this preview environment. No data was lost and the rest of the system remains available.
          </p>
          <a
            href="#/dashboard"
            className="mt-6 inline-flex rounded-lg bg-indigo-600 px-4 py-2 text-sm font-semibold text-white hover:bg-indigo-700"
          >
            Back to Dashboard
          </a>
        </div>
      </div>
    )
  }

  return <>{children}</>
}

export default ProtectedRoute
