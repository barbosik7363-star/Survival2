
struct NavView: View {
    @EnvironmentObject var nav: Nav
    @State private var name = ""
    @State private var adding = false
    @State private var mode = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("Режим", selection: $mode) {
                        Text("Компас").tag(0)
                        Text("Карта").tag(1)
                    }
                    .pickerStyle(.segmented)

                    Group {
                        if mode == 0 {
                            RadarView().frame(height: 330).card()
                                .transition(.opacity.combined(with: .scale(0.96)))
                        } else {
                            OfflineMapCard()
                                .transition(.opacity.combined(with: .scale(0.96)))
                        }
                    }
                    .animation(.smooth, value: mode)

                    HStack {
                        Text("\(Int(nav.heading))° \(nav.direction)")
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            if let l = nav.loc {
                                Text(String(format: "%.5f, %.5f", l.coordinate.latitude, l.coordinate.longitude))
                                Text("±\(Int(max(l.horizontalAccuracy, 0))) м, высота \(Int(l.altitude)) м").foregroundStyle(.secondary)
                            } else {
                                Text("Ищу GPS…").foregroundStyle(.secondary)
                            }
                        }
                        .font(.footnote)
                    }
                    .card()

                    Button { adding = true } label: {
                        Label("Отметить точку здесь", systemImage: "mappin.and.ellipse").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass).controlSize(.large)
                    .disabled(nav.loc == nil)

                    ForEach(nav.points) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.headline)
                                if let me = nav.loc {
                                    Text(Nav.dist(me.distance(from: p.location))).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let me = nav.loc {
                                Image(systemName: "location.north.fill").font(.title2)
                                    .rotationEffect(.degrees(Nav.bearing(from: me, to: p.location.coordinate) - nav.heading))
                            }
                            Button { nav.points.removeAll { $0.id == p.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).padding(.leading, 12)
                        }
                        .card()
                        .transition(.scale(0.9).combined(with: .opacity))
                    }
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: nav.points.count)

                    Text("Карта и компас работают без интернета. Отметьте лагерь или машину, и стрелка всегда покажет путь назад.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
                .padding()
            }
            .background { Orbs() }
            .navigationTitle("Карта")
            .alert("Название точки", isPresented: $adding) {
                TextField("Лагерь", text: $name)
                Button("Сохранить") { nav.addHere(name); name = "" }
                Button("Отмена", role: .cancel) { name = "" }
            }
        }
    }
}
