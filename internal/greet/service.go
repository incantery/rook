package greet

type Service struct{}

func (s *Service) Greet(name string) string {
	return "Hello " + name + "!"
}
